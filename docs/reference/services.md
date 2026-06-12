# Services — what runs where, and how each one is configured

Hostnames, backends, image constraints, and the config that has to line
up for each service to work — the stuff that isn't obvious from the
manifests alone. For the reasoning behind the decisions see the ADRs;
for how a request actually flows see architecture.md.

## Live services

| Service | LAN | Public | Backend |
|---|---|---|---|
| Gitea | gitea.lan | git.henrydowd.dev | k3s pod (`gitea` ns) |
| Nextcloud | nextcloud.lan | nextcloud.henrydowd.dev | k3s pod (`nextcloud` ns) |
| Collabora (CODE) | collabora.lan | collabora.henrydowd.dev | k3s pod (`collabora` ns) |
| Kiwix | wiki.lan | wiki.henrydowd.dev | k3s pod (`kiwix` ns) |
| Immich | immich.lan | immich.henrydowd.dev | k3s pod (`immich` ns) |
| Grafana | grafana.lan | grafana.henrydowd.dev | k3s pod (`monitoring` ns) |
| AMP | amp.lan | amp.henrydowd.dev | LXC 102, 192.168.1.15:8080 |
| Proxmox | proxmox.lan | proxmox.henrydowd.dev | host, 192.168.1.2:8006 (HTTPS, self-signed) |
| Technitium (admin UI) | technitium.lan | — | LXC 100, 192.168.1.5:5380 |
| ArgoCD | argocd.lan | — | k3s pod (`argocd` ns) — deliberately LAN-only |
| WireGuard/SSH | — | home.henrydowd.dev | LXC 101 (DNS-only A record, not proxied) |

Technitium's row is ingress glue only — the DNS server itself runs on
the LXC, not in the cluster. Same selectorless-Service + EndpointSlice
pattern as AMP and Proxmox (see architecture.md).

## Cluster components

| Component | Namespace | Notes |
|---|---|---|
| Longhorn | longhorn-system | Default StorageClass · worker vdb 500GB · replica count 1 (single worker) · daily snapshots, retain 7 |
| ArgoCD | argocd | Watches `main` · UI at argocd.lan · `server.insecure` mode behind Traefik · port-forward 8080:443 as fallback |
| Sealed Secrets | kube-system | Master key backed up to local disk + password manager |
| MetalLB | metallb-system | Pool 192.168.1.200–210, L2 mode |
| Traefik | traefik | Chart pinned · LB 192.168.1.200 · `web` :8000 / `websecure` :8443 |
| cloudflared | cloudflared | `*.henrydowd.dev` wildcard tunnel → Traefik over plain HTTP |
| VictoriaMetrics stack | monitoring | vmsingle + vmalert + Alertmanager + Grafana · 30d TSDB on local-path · pinned to worker · email alerts via Brevo SMTP relay — see ADR 005 and the comments in `k8s/infrastructure/victoria-metrics.yaml` |

## DNS

- Technitium on LXC 100, **192.168.1.5** — the LAN resolver.
- `*.lan` → 192.168.1.200 and `*.henrydowd.dev` → 192.168.1.200
  (split-horizon: LAN traffic to public hostnames stays local).
- `home.henrydowd.dev` — Cloudflare A record (DNS-only, not proxied),
  kept current by cloudflare-ddns on the WireGuard LXC
  (`/usr/local/bin/cloudflare-ddns.sh`, cron every 5 min; only PUTs when
  the IP actually changed, logs changes and failures to
  `/var/log/cloudflare-ddns.log` in the container).

## Nextcloud

- Image: `nextcloud:33-apache`. Stay on 33.x — Nextcloud only supports
  one-major-at-a-time upgrades, see the comment in
  `k8s/apps/nextcloud/nextcloud.yaml`.
- DB: Postgres 18, Service `postgres`, db `nextcloud_database`, user
  `nextcloud`, table prefix `oc_`.
- Cache/locking: Redis, no auth, no persistence (throwaway state).
- Storage: Longhorn PVC `nextcloud-data` 60Gi at `/var/www/html`,
  `nextcloud-db` 10Gi for Postgres.
- Identity: `instanceid`/`secret`/`passwordsalt` live in the
  `nextcloud-secrets` SealedSecret and **must match the imported DB**
  (see gotchas.md).
- Background jobs: CronJob `nextcloud-cron` every 5 min, shares the data
  PVC via podAffinity.
- Disabled apps (AIO orphans): `notify_push`, `workflow_ocr`.
- `richdocuments` is enabled against the self-hosted CODE below.
- TODO: re-enable calendar, contacts, notes, tasks, deck.

## Collabora (CODE)

- Image: `collabora/code` (pinned in the deployment), namespace
  `collabora`, pinned to the worker.
- WOPI: `wopi_url = http://collabora.collabora.svc.cluster.local:9980`
  (in-cluster HTTP) · `public_wopi_url = https://collabora.henrydowd.dev`.
- **INTERIM:** the pod uses `dnsPolicy: None` + public resolvers so its
  WOPI reachback to `nextcloud.henrydowd.dev` gets Cloudflare's valid
  cert. Delete once cert-manager issues a real Traefik cert — comment in
  `k8s/apps/collabora/deployment.yaml`.
- The securityContext (AppArmor `Unconfined` **field** + capability
  list) is load-bearing — see gotchas.md.
- Keep personal wordbooks small — an uploaded hunspell `.dic` caused
  ~55s cold opens. See
  `docs/lessons/k8s/collabora-slow-load-wordbook.md`.

## Immich

- Images: `immich-server` + `immich-machine-learning` v2.7.5, plus
  Immich's own `postgres:14-vectorchord` build — the three are
  version-paired, bump them together from the release's docker-compose
  (see ADR 006).
- Storage: Longhorn PVC `immich-library` 200Gi at `/data` (originals,
  thumbs, encoded video) · `immich-db` 10Gi · ML model cache 10Gi on
  local-path (regenerable).
- Cache/queue: Valkey, no persistence.
- SealedSecrets: `immich-secrets` (DB password) ·
  `backup-credentials` (B2 + restic, repo `.../immich`).
- Everything pinned to the worker; the ML container has the biggest
  memory limit in the cluster (3Gi) — it's the thing to watch during a
  big import.
- **Uploads >100MB fail through the Cloudflare tunnel** (per-request
  cap). At home this never applies — split-horizon sends
  `immich.henrydowd.dev` straight to Traefik. Remote large videos: use
  the WireGuard VPN, or let the app retry when the phone gets home.
- Backup: 04:00 nightly to `hpd.homelab/immich`, `thumbs/` and
  `encoded-video/` excluded as regenerable.

## Gitea

- Image: `gitea/gitea` (pinned in the deployment).
- Data on `/data` (Longhorn PVC), config generated by an init container
  into `/data/gitea/conf/app.ini` — edit the init container, not the
  live file.
- DB: SQLite inside the data PVC — which is why its backup scales the
  deployment to 0 first (see ADR 004).
- SealedSecret: `lfs-jwt-secret` · `internal-token` · `oauth2-jwt-secret`.

## Backups (summary)

restic → Backblaze B2, bucket `hpd.homelab`
(`s3.eu-central-003.backblazeb2.com`). Per-service repos:
`.../nextcloud` (03:00, no downtime, tags `nextcloud-data` +
`nextcloud-db`) · `.../gitea` (03:30, scales to 0, tag `gitea-data`) ·
`.../immich` (04:00, no downtime, tags `immich-data` + `immich-db`).
Retention 7 daily / 4 weekly / 3 monthly. Credentials in a
`backup-credentials` SealedSecret per namespace; **`RESTIC_PASSWORD` is
in the password manager — losing it loses the backups.** The why: ADR
004. Restore: `docs/runbooks/restore-procedure.md` (including the
test-restore log).

Not backed up, on purpose:

- **AMP (LXC 102) and Technitium (LXC 100)** — both on `local-lvm`, so
  neither the nightly ZFS snapshots (tank only) nor vzdump (no jobs
  configured) covers them. Loss means rebuilding by hand: reinstall +
  re-add the DNS zones / game server config. Accepted for now; revisit
  if either accumulates state worth keeping.
- **QBittorrent (VM 201)** — disposable by design, currently stopped.
- **Monitoring TSDB** — regenerable, see ADR 005.
