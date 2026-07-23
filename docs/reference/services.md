# Services: what runs where, and how each one is configured

Hostnames, backends, image constraints, and the config that has to line
up for each service to work, the stuff that isn't obvious from the
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
| Paperless | paperless.lan | paperless.henrydowd.dev | k3s pod (`paperless` ns) |
| Grafana | grafana.lan | — | k3s pod (`monitoring` ns) — deliberately LAN-only |
| Portfolio (CV site) | — | henrydowd.dev, www.henrydowd.dev | k3s pod (`portfolio` ns) |
| Homepage (dashboard) | dash.lan | dash.henrydowd.dev, home.dowd.ie | k3s pod (`homepage` ns) — public + ungated, links only |
| AMP | amp.lan | amp.henrydowd.dev | LXC 102, 192.168.1.15:8080 |
| Proxmox | proxmox.lan | proxmox.henrydowd.dev | host, 192.168.1.2:8006 (HTTPS, self-signed) |
| Technitium (admin UI) | technitium.lan | — | LXC 100, 192.168.1.5:5380 |
| ArgoCD | argocd.lan | — | k3s pod (`argocd` ns) — deliberately LAN-only |
| WireGuard/SSH | — | home.henrydowd.dev | LXC 101 (DNS-only A record, not proxied) |

Technitium's row is ingress glue only, the DNS server itself runs on
the LXC, not in the cluster. Same selectorless-Service + EndpointSlice
pattern as AMP and Proxmox (see architecture.md).

The portfolio sits on the bare apex `henrydowd.dev` (+ `www`) and has no
`.lan` alias, but split-horizon still applies: Technitium answers the
apex A record directly, so on the LAN it resolves to Traefik like
everything else (the `*.henrydowd.dev` wildcard can't match the zone
root). See ADR 009.

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

- Technitium on LXC 100, **192.168.1.5**, the LAN resolver.
- `*.lan` → 192.168.1.200 and `*.henrydowd.dev` → 192.168.1.200
  (split-horizon: LAN traffic to public hostnames stays local).
- `home.henrydowd.dev`, Cloudflare A record (DNS-only, not proxied),
  kept current by cloudflare-ddns on the WireGuard LXC
  (`/usr/local/bin/cloudflare-ddns.sh`, cron every 5 min; only PUTs when
  the IP actually changed, logs changes and failures to
  `/var/log/cloudflare-ddns.log` in the container).

## Nextcloud

- Image: `nextcloud:33-apache`. Stay on 33.x, Nextcloud only supports
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
- WOPI reachback to `nextcloud.henrydowd.dev` goes cluster DNS →
  Technitium → Traefik, and the cert-manager wildcard verifies (openssl
  return 0 from the pod). The old `dnsPolicy: None` + public-resolver
  hairpin was **removed 2026-06-12**; it was silently broken anyway
  (the Vodafone hub drops outbound :53, so the pod could never resolve
  through it) and ADR 007's real Traefik cert made it unnecessary.
- The securityContext (AppArmor `Unconfined` **field** + capability
  list) is load-bearing, see gotchas.md.
- Keep personal wordbooks small, an uploaded hunspell `.dic` caused
  ~55s cold opens. See
  `docs/lessons/k8s/collabora-slow-load-wordbook.md`.

## Immich

- Images: `immich-server` + `immich-machine-learning` v2.7.5, plus
  Immich's own `postgres:14-vectorchord` build, the three are
  version-paired, bump them together from the release's docker-compose
  (see ADR 006).
- Storage: Longhorn PVC `immich-library` 200Gi at `/data` (originals,
  thumbs, encoded video) · `immich-db` 10Gi · ML model cache 10Gi on
  local-path (regenerable).
- Cache/queue: Valkey, no persistence.
- SealedSecrets: `immich-secrets` (DB password) ·
  `backup-credentials` (B2 + restic, repo `.../immich`).
- Everything pinned to the worker; the ML container has the biggest
  memory limit in the cluster (3Gi); it's the thing to watch during a
  big import.
- **`immich-ml` runs unhardened** (default securityContext) — its
  ONNX/uvicorn worker hangs under the ADR 011 drop-caps + seccomp
  profile the rest of the cluster took. Documented exception like
  Collabora (ADR 011 carve-out 1); `immich-server` *is* hardened. No
  NetworkPolicy either — the immich one was reverted (fresh-pod race,
  see the netpol lesson).
- **Uploads >100MB fail through the Cloudflare tunnel** (per-request
  cap). At home this never applies, split-horizon sends
  `immich.henrydowd.dev` straight to Traefik. Remote large videos: use
  the WireGuard VPN, or let the app retry when the phone gets home.
- Backup: 04:00 nightly to `hpd.homelab/immich`, `thumbs/` and
  `encoded-video/` excluded as regenerable.

## Paperless

- Image: `paperless-ngx:v3.0.0` (Tantivy search backend) — one image runs
  gunicorn + Celery workers + the consumer under supervisord. Bump only
  after checking the release's docker-compose for the paired Postgres major
  (see ADR 015).
- DB: stock `postgres:18-alpine`, Service `postgres`, db/user `paperless`
  (not Immich's VectorChord build). Broker: Valkey, no persistence.
- Storage: Longhorn PVCs `paperless-media` 20Gi (irreplaceable originals +
  OCR archive) · `paperless-data` 5Gi (search index/config) ·
  `paperless-consume` 1Gi (watch folder) · `paperless-db` 10Gi.
- SealedSecrets: `paperless-secrets` (SECRET_KEY, DBPASS, bootstrap admin) ·
  `backup-credentials` (B2 + restic, repo `.../paperless`).
- **Reverse-proxy env is load-bearing**: `PAPERLESS_PROXY_SSL_HEADER` +
  `PAPERLESS_TRUSTED_PROXIES=10.42.0.0/16` — without them Django sees plain
  HTTP over the tunnel and redirect-loops / CSRF-403s the login.
- OCR is capped (`TASK_WORKERS=1`, `THREADS_PER_WORKER=1`, limit 1.5Gi) to
  fit the tight worker; peak scales with the document, so a big scan can
  spike — stagger bulk ingest away from Immich imports.
- Auth: native login now; Authelia **OIDC** planned after phase 8 (Paperless
  Mobile hits `/api` directly, so OIDC not ForwardAuth).
- Ingest: drop files into the `consume` PVC (watch folder); they're OCR'd,
  tagged, and indexed automatically.
- Backup: 04:30 nightly to `hpd.homelab/paperless` (`pg_dump` + media RO
  mount, no scale-to-0). Plus a periodic manual `document_exporter` for
  version-portable insurance — see the runbook.

## Gitea

- Image: `gitea/gitea` (pinned in the deployment).
- Data on `/data` (Longhorn PVC), config generated by an init container
  into `/data/gitea/conf/app.ini`, edit the init container, not the
  live file.
- DB: SQLite inside the data PVC, which is why its backup scales the
  deployment to 0 first (see ADR 004).
- SealedSecret: `lfs-jwt-secret` · `internal-token` · `oauth2-jwt-secret`.
- **Actions enabled** (`[actions]` in app.ini), CI on this GitOps repo.
  An in-cluster `act_runner` (`gitea/act_runner` + `docker:dind`
  sidecar, privileged, pinned to the worker) registers via the
  `gitea-act-runner` SealedSecret; PVCs `act-runner-dind` 15Gi (image
  layers, on tank) + `act-runner-data` 5Gi. The workflow
  `.gitea/workflows/manifests.yaml` runs kubeconform over `k8s/**`.
  Heavy builds (e.g. NextKeep Android) are offloaded to GitHub-hosted
  runners, the worker can't host them. Two bring-up gotchas (DinD MTU
  1450, act_runner `GOMEMLIMIT`) live in gotchas.md. See ADR 008.

## Portfolio (CV site)

- The public CV/personal site on the bare apex `henrydowd.dev` (+
  `www`). Built from a **separate repo**
  (`git.henrydowd.dev/henry/portfolio`), not this one, a single static
  Go binary that embeds the built site and serves it plus a small
  `/api` on `:8080`, with `/metrics` + `/healthz` on a separate `:9090`
  the Ingress never routes.
- **Holds no secrets.** It reads cluster-internal data with no auth,
  VictoriaMetrics for live stats, and Gitea for this repo's recent
  commits (the `henry/homelab` repo is public, read anonymously),
  wired via `VM_URL`/`GITEA_URL`/`GITEA_REPO` env in the deployment, so
  a compromise of the public pod leaks nothing.
- **Self-built image, not upstream:** GitHub Actions builds it and
  pushes to GHCR (`ghcr.io/hpdowd/portfolio`), pulled anonymously like
  Immich. The in-cluster runner can't build it (no daemon in-job, see
  gotchas.md); the build rides the GitHub push-mirror. See ADR 008/009.
- **Self-monitored:** a `VMServiceScrape` targets `:9090/metrics`, so
  the service that surfaces homelab telemetry is itself a scraped
  target; its Grafana dashboard + `homelab.portfolio` upstream alerts
  live in `k8s/apps/monitoring/`.
- Stateless, no PVC, `strategy: RollingUpdate`, nothing to back up.

## Homepage (dashboard)

- `gethomepage/homepage`, pinned `v1.13.2`, namespace `homepage`, pinned to
  the worker. One stateless container, no DB, no PVC — all config is the
  `homepage` ConfigMap in git, so a pod loss just re-renders the page.
- **Auth state: public + ungated, links only.** The first pass ships a link
  grid + bookmarks with **no** `widget:` blocks and no API keys — a link is a
  hostname DNS already publishes. Live-data widgets (Grafana/Immich/Proxmox
  polling their APIs with stored keys) are deferred to phase 8, once
  `dash.henrydowd.dev` sits behind Authelia `one_factor`; adding keyed widgets
  before that would paint infra telemetry onto a world-readable page. See
  `docs/plans/phase-9-homepage.md` step 4.
- **`HOMEPAGE_ALLOWED_HOSTS` is load-bearing** (`$(MY_POD_IP):3000,dash.lan,dash.henrydowd.dev`).
  The pod-IP entry is required or the kubelet probe — which hits the pod IP,
  not a hostname — 400s on host validation and the pod never goes Ready. The
  health endpoint is `/api/healthcheck` (v1.x; not `GET /`).
- **Read-only root filesystem:** two `emptyDir` scratch mounts, `/app/.next/cache`
  (Next.js render cache) and `/app/config/logs`. The ConfigMap ships all files
  homepage looks for (incl. empty `docker.yaml`/`kubernetes.yaml`/`custom.*`)
  because it can't create missing defaults on a read-only mount.
- **A ConfigMap edit does NOT hot-reload** — after editing config,
  `kubectl -n homepage rollout restart deploy/homepage`.
- Nothing to back up (stateless; config in git). The `dash.*` hosts carry no
  `tls:` block (ADR 007) and ride the `*.henrydowd.dev` wildcard for
  cert/DNS/tunnel.
- **`home.dowd.ie`** is a third hostname on a separate Cloudflare zone, so it's
  the ADR-007 exception (like file-parser's `secure.dowd.ie`): a per-Ingress
  `tls:` block loads `dowd-ie-tls`, issued into the `homepage` ns by its own
  `*.dowd.ie` Certificate (`k8s/apps/homepage/certificate.yaml` — the shared
  file-parser cert can't cross namespaces, the dowd-ie-cert-wrong-namespace
  lesson). Its cloudflared public-hostname route (token-mode tunnel =
  dashboard-managed) and Technitium `home.dowd.ie → 192.168.1.200` record are
  **not in this repo**; `home.dowd.ie` is also in `HOMEPAGE_ALLOWED_HOSTS` or it
  would 400. Kept out of any Cloudflare Access app so it stays public.

## Backups (summary)

restic → Backblaze B2, bucket `hpd.homelab`
(`s3.eu-central-003.backblazeb2.com`). Per-service repos:
`.../nextcloud` (03:00, no downtime, tags `nextcloud-data` +
`nextcloud-db`) · `.../gitea` (03:30, scales to 0, tag `gitea-data`) ·
`.../immich` (04:00, no downtime, tags `immich-data` + `immich-db`).
Retention 7 daily / 4 weekly / 3 monthly. Credentials in a
`backup-credentials` SealedSecret per namespace; **`RESTIC_PASSWORD` is
in the password manager, losing it loses the backups.** The why: ADR
004. Restore: `docs/runbooks/restore-procedure.md` (including the
test-restore log).

Not backed up, on purpose:

- **AMP (LXC 102) and Technitium (LXC 100):** both on `local-lvm`, so
  neither the nightly ZFS snapshots (tank only) nor vzdump (no jobs
  configured) covers them. Loss means rebuilding by hand: reinstall +
  re-add the DNS zones / game server config. Accepted for now; revisit
  if either accumulates state worth keeping.
- **QBittorrent (VM 201):** disposable by design, currently stopped.
- **Monitoring TSDB:** regenerable, see ADR 005.
- **Portfolio:** stateless (no PVC); the image is rebuilt from git by
  CI, so there's nothing to restore.
