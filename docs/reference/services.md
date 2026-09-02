# Services: what runs where, and how each one is configured

Hostnames, backends, image constraints, and the config that has to line
up for each service to work, the stuff that isn't obvious from the
manifests alone. For the reasoning behind the decisions see the ADRs;
for how a request actually flows see architecture.md.

## Live services

| Service | LAN | Public | Backend | Auth on the public host |
|---|---|---|---|---|
| Authelia | — (see note) | auth.henrydowd.dev | k3s pod (`authelia` ns) | n/a — it *is* the login |
| file-parser | — | secure.henrydowd.dev, secure.dowd.ie | k3s pod (`file-parser` ns) | Cloudflare Access (stays there, not Authelia) |
| Gitea | gitea.lan | git.henrydowd.dev | k3s pod (`gitea` ns) | native (Authelia OIDC pending) |
| Nextcloud | nextcloud.lan | nextcloud.henrydowd.dev | k3s pod (`nextcloud` ns) | native (Authelia OIDC pending) |
| Collabora (CODE) | collabora.lan | collabora.henrydowd.dev | k3s pod (`collabora` ns) | none by design (WOPI backend) |
| Kiwix | wiki.lan | wiki.henrydowd.dev | k3s pod (`kiwix` ns) | **Authelia ForwardAuth, one_factor** |
| Immich | immich.lan | immich.henrydowd.dev | k3s pod (`immich` ns) | native (Authelia OIDC pending) |
| Paperless | paperless.lan | paperless.henrydowd.dev | k3s pod (`paperless` ns) | native (Authelia OIDC pending) |
| Grafana | grafana.lan | — | k3s pod (`monitoring` ns) — deliberately LAN-only | LAN-only |
| Portfolio (CV site) | — | henrydowd.dev, www.henrydowd.dev | k3s pod (`portfolio` ns) | none by design (public CV, no secrets) |
| Homepage (dashboard) | dash.lan | dash.henrydowd.dev, home.dowd.ie | k3s pod (`homepage` ns) | **ForwardAuth one_factor on dash.henrydowd.dev only** — `home.dowd.ie` is still public, see below |
| AMP | amp.lan | amp.henrydowd.dev | LXC 102, 192.168.1.15:8080 | **Authelia ForwardAuth, two_factor** |
| Proxmox | proxmox.lan | proxmox.henrydowd.dev | host, 192.168.1.2:8006 (HTTPS, self-signed) | **Cloudflare Access + ForwardAuth two_factor, tunnel path only** (three logins with PVE's own) — LAN HTTPS is ungated by design (ADR 018) |
| Technitium (admin UI) | technitium.lan | — | LXC 100, 192.168.1.5:5380 | LAN-only |
| ArgoCD | argocd.lan | — | k3s pod (`argocd` ns) — deliberately LAN-only | LAN-only |
| WireGuard/SSH | — | home.henrydowd.dev | LXC 101 (DNS-only A record, not proxied) | network layer, outside Authelia |

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

## Authelia (SSO)

- **One hostname, `auth.henrydowd.dev`, with no `.lan` alias** — the exception
  to the pattern every other service follows. A host that matches no
  `session.cookies` domain serves the portal HTML but 403s every API call, so
  an `auth.lan` would render a login page that refuses every submission.
  Split-horizon already resolves `auth.henrydowd.dev` on the LAN, and the
  session cookie plus every OIDC `redirect_uri` are pinned to that one name.
- `docker.io/authelia/authelia`, pinned **4.39.20**, namespace `authelia`,
  worker-pinned, one replica, `strategy: Recreate` (RWO PVC). ~100Mi resident.
  See ADR 018 for why Authelia and not Authentik/Cloudflare Access.
- **The image tag is not a detail.** Authelia's config schema drifts between
  4.x minors and it refuses to start on an unknown key rather than ignoring it,
  so a floating tag turns an unattended autosync into a cluster-wide auth
  outage. Before any bump, re-run the validator named in `configmap.yaml`:
  `docker run --rm -v "$PWD:/c" authelia/authelia:<tag> authelia validate-config
  --config /c/configuration.yml`.
- Runs as **uid 1000, all capabilities dropped, read-only root filesystem**.
  That last one only works because `server.disable_healthcheck: true` stops it
  writing `/app/.healthcheck.env` on boot; the pod is probed with httpGet on
  `/api/health` and never uses the image's own healthcheck script.
- **Two startup checks are deliberately declawed** (ADR 018): the SMTP notifier
  check is disabled outright, because a relay that refuses the connection is
  otherwise *fatal* and would let a Brevo outage 502 every gated service; and
  NTP runs with `disable_failure: true`, so an unreachable time server logs a
  warning instead of blocking startup.
- SealedSecrets: `authelia-secrets` (jwt_secret, session_secret,
  storage_encryption_key, smtp_password) and `authelia-users` (`users.yml`,
  argon2 hashes). Mounted as **files** and read via `AUTHELIA_*_FILE` env vars,
  never as literal env values. `storage_encryption_key` is under the same loss
  policy as `RESTIC_PASSWORD` — lose it and `db.sqlite3` is unreadable.
- PVC `authelia-data` 1Gi (SQLite: TOTP enrolments, OIDC consents, the
  brute-force ledger). **Not backed up and deliberately not `Prune=false`** —
  it is regenerable, see ADR 018.
- ACLs live in the ConfigMap in plain git (`access_control.rules`). A rule is
  **inert** until the matching Ingress/IngressRoute carries the
  `authelia-forwardauth@kubernetescrd` middleware, so rules can ship ahead of
  enforcement. The inverse is not safe: annotate a host that has no rule and
  `default_policy: deny` gives it a hard 403.
- **Two** Middlewares in the `authelia` namespace, referenced cross-namespace
  and always chained in this order:
  `authelia-forceproto@kubernetescrd,authelia-forwardauth@kubernetescrd`.
  `forceproto` is not optional — Authelia 400s any target with an http scheme,
  and the tunnel reaches Traefik as plain HTTP, so without it every gated host
  works on the LAN and fails from the internet. Cross-namespace referencing
  needs
  `providers.kubernetesCRD.allowCrossNamespace=true` on Traefik. It sets
  `trustForwardHeader: true` so the client IP reaches Authelia for the `lan`
  network rule — safe only because Traefik's `forwardedHeaders.trustedIPs` is
  empty and it therefore overwrites any spoofed `X-Forwarded-For`. **Never add
  the pod CIDR (10.42.0.0/16) to trustedIPs or to the `lan` network**: tunnel
  traffic arrives from it, so either would make the whole internet count as LAN.
  Note that Authelia's own Traefik guide lists `maxResponseBodySize`, which is
  not a field in the Middleware CRD and is rejected by the API server.
- **Every gated service keeps an ungated path** — `wiki.lan`, `dash.lan`,
  `amp.lan` as separate bare Ingress objects, and Proxmox's LAN HTTPS route.
  That is the break-glass route when Authelia is down, and the reason the LAN
  bypass exists at all (ADR 018).
- Metrics on `:9959`, scraped by `k8s/apps/monitoring/authelia-scrape.yaml`,
  alerted by `AutheliaDown` / `AutheliaMetricsAbsent` in `homelab-rules.yaml`.

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

- Image: `paperless-ngx:3.0.0` (Tantivy search backend; image tags have no
  `v` prefix) — one image runs
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
- Auth: native login now; Authelia **OIDC** still pending. Paperless Mobile
  hits `/api` directly, so this must be OIDC and must NOT be ForwardAuth'd —
  a middleware on this Ingress would break the mobile app. See ADR 018 and
  step 5 of `docs/plans/phase-8-authelia.md`.
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
- **Auth state: partially gated, and the widgets are still blocked.**
  `dash.henrydowd.dev` now sits behind Authelia ForwardAuth (`one_factor`) via
  its own Ingress object; `dash.lan` and `home.dowd.ie` are served by a second,
  bare Ingress (`homepage-ungated`).
  **`home.dowd.ie` is the catch:** it is public, it answers the same pod, and
  being a second apex it cannot share the `henrydowd.dev` session cookie, so it
  cannot be ForwardAuth'd without a redirect loop. The dashboard is therefore
  still world-readable, and the live-data widgets (Grafana/Immich/Proxmox
  polling their APIs with stored keys) remain **unsafe to add** despite the
  phase-9 precondition technically reading as met. That stays blocked until the
  `dowd.ie` decision in ADR 018 is made. See `docs/plans/phase-9-homepage.md`
  step 4.
- **`HOMEPAGE_ALLOWED_HOSTS` is load-bearing** (`$(MY_POD_IP):3000,dash.lan,dash.henrydowd.dev`).
  The pod-IP entry is required or the kubelet probe — which hits the pod IP,
  not a hostname — 400s on host validation and the pod never goes Ready. The
  health endpoint is `/api/healthcheck` (v1.x; not `GET /`).
- **Read-only root filesystem, three writable `emptyDir`s.** `/app/config`
  (seeded by an initContainer with the files we author; homepage creates its
  own skeleton files there at runtime — the readonly-config-erofs lesson),
  `/app/.next/cache` (Next.js render cache), and `/app/.next/server/pages`
  (seeded from the image by the `seed-prerender` initContainer). That last one
  is not optional: homepage serves a **prerendered** page and rewrites it via
  `/api/revalidate`; without a writable path that write fails EROFS and the
  dashboard silently serves the image's demo page while still returning 200 —
  the prerender-erofs lesson. A `startupProbe` on `/api/revalidate` regenerates
  the page once before the pod goes Ready.
- **Look:** `custom.css` ships as a ConfigMap key (hence the initContainer's
  `cp -L /defaults/*`, not `*.yaml`) and is served at `/api/config/custom.css`.
  It loads *before* homepage's own stylesheet, so its selectors are id-scoped
  (`#page_wrapper …`) to win on specificity instead of using `!important`.
  Everything else is `settings.yaml`: `headerStyle: clean`, `useEqualHeights`,
  no group icons.
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
