# Phase 10: Paperless-ngx document archive walkthrough

*Drafted 2026-07-22. Pin the exact `ghcr.io/paperless-ngx/paperless-ngx`
release and check its `docker-compose.yml` for the paired Postgres/Redis
versions before deploying — Paperless bumps its expected PG major and its env
keys between minors. Verify `PAPERLESS_*` keys against the pinned version's
docs.*

Architecture: three pods, the Immich shape (web + Postgres + broker):

- **paperless-ngx** — one image runs gunicorn (web), the Celery task workers,
  and the consumer together under supervisord.
- **Postgres** — its own Deployment (immich/nextcloud pattern), not SQLite:
  concurrent OCR workers + full-text search deadlock SQLite under Celery.
- **Valkey** — broker/result cache, no persistence (queue state only; a
  restart just re-runs an in-flight consume).

**No Tika/Gotenberg** (your call) — OCR covers PDFs and scanned images, which
is the bulk of household paper. `.docx/.xlsx/.eml` ingest would need those two
sidecars (~300–400Mi more against the worker's NodeMemoryLowWorker gate); add
them later if it turns out you actually need Office/email consumption.

Decisions to record in ADR 015 before starting (step 0).

## Step 0: ADR 015 + preflight

Write `docs/adr/015-paperless-ngx.md`:

| Decision | Choice | Why |
|---|---|---|
| DB | Postgres (own Deployment) | concurrent OCR + FTS; SQLite locks under Celery concurrency |
| Broker | Valkey, no persistence | queue/cache only; lost queue re-runs consume |
| Office/email | **excluded** (no Tika/Gotenberg) | RAM budget; PDFs+images cover the household |
| Storage | Longhorn PVCs: `data` 5Gi · `media` 20Gi (grows) · `consume` 1Gi · `db` 10Gi | `media` holds the irreplaceable originals + OCR'd archive |
| OCR language | `PAPERLESS_OCR_LANGUAGE=eng` | add `deu`/`fra`… via `PAPERLESS_OCR_LANGUAGES` (apt packs) if needed |
| Concurrency | `WEBSERVER_WORKERS=2`, `TASK_WORKERS=1`, `THREADS_PER_WORKER=1` | OCR is RAM-bursty; cap it to fit the tight worker, accept slower bulk ingest |
| Auth | native now, Authelia **OIDC** after phase 8 | Paperless Mobile hits `/api` directly — OIDC not ForwardAuth (the Authelia plan's rule); keep native login too |
| Exposure | `paperless.lan` + `paperless.henrydowd.dev`, public via tunnel | sensitive docs — same data-handling class as file-parser |
| Backup | restic → B2 (new repo) — `media` RO-mount + `pg_dump`, plus periodic `document_exporter` | media files are immutable once ingested; no scale-to-0 needed |

Preflight:

```bash
kubectl top nodes                                   # worker headroom before adding 3 pods + OCR bursts
kubectl -n longhorn-system get volumes.longhorn.io  # note vdb free — media grows, Longhorn grows online but can't shrink
# Current release + its compose-pinned PG/redis versions:
# https://github.com/paperless-ngx/paperless-ngx/releases
```

DNS/cert/tunnel need **zero work**: `paperless.henrydowd.dev` rides the
`*.henrydowd.dev` wildcard (Technitium split-horizon on LAN, cloudflared
wildcard publicly, LE wildcard TLSStore cert) and resolves the moment the
Ingress exists.

---

## Step 1: secrets

```bash
openssl rand -hex 64    # PAPERLESS_SECRET_KEY (keep stable — rotating it drops sessions, not data)
openssl rand -hex 24    # PAPERLESS_DBPASS
```

`SealedSecret` `paperless-secrets` (controller in kube-system; see
operations.md):

```bash
kubectl create secret generic paperless-secrets -n paperless \
  --from-literal=PAPERLESS_SECRET_KEY=... \
  --from-literal=PAPERLESS_DBPASS=... \
  --from-literal=PAPERLESS_ADMIN_USER=henry \
  --from-literal=PAPERLESS_ADMIN_PASSWORD=... \
  --dry-run=client -o yaml | kubeseal --format yaml > k8s/apps/paperless/sealed-secret.yaml
```

`PAPERLESS_ADMIN_USER/PASSWORD` bootstrap the superuser on **first run only**
(ignored once the user table exists). Password-manager copies of all of it;
`PAPERLESS_SECRET_KEY` especially. The OIDC client secret is added to this
SealedSecret in step 4.

---

## Step 2: manifests

`k8s/apps/paperless/` **plus** `k8s/apps/paperless.yaml` (non-recursive
root-app gotcha):

- `namespace.yaml`, `sealed-secret.yaml`
- `postgres.yaml` — copy `immich/postgres.yaml`, but the **stock**
  `postgres:17-alpine` (not Immich's VectorChord build), db `paperless`, user
  `paperless`, `PGDATA=/var/lib/postgresql/data/pgdata` (lost+found dodge),
  `shm` emptyDir, `strategy: Recreate` (RWO), pinned to worker, root-then-drop
  caps (`CHOWN,DAC_OVERRIDE,FOWNER,SETGID,SETUID`), `db` PVC 10Gi.
- `redis.yaml` — copy `immich/redis.yaml` verbatim (valkey, fully locked down,
  `--save "" --appendonly no`, emptyDir `/data`).
- `pvc.yaml` — `paperless-data` 5Gi, `paperless-media` 20Gi, `paperless-consume`
  1Gi (all Longhorn).
- `deployment.yaml` — the paperless image, single replica, `strategy:
  Recreate` (RWO media/data), pinned to worker, `enableServiceLinks: false`
  (hygiene — kill the `REDIS_PORT` docker-link injection, same reason as
  Immich), root-then-drop caps (image starts root, maps to uid 1000 via s6,
  then drops), `requests: 512Mi/250m`, `limits: 1.5Gi` (OCR spikes; watch and
  raise if a big scan OOMs — the file-parser lesson: peak scales with the
  document being OCR'd, not steady state). Volumes → `/usr/src/paperless/{data,
  media,consume}`.

  **startupProbe with generous grace** — first boot runs DB migrations and a
  version bump re-runs them; copy Immich's `periodSeconds: 5,
  failureThreshold: 60` (5 min) on `httpGet: /` (returns 200/302, no
  unauthenticated health endpoint exists). liveness/readiness on `/` too.

  Env — the reverse-proxy set is **load-bearing** behind the plain-HTTP tunnel:

  ```yaml
  - { name: PAPERLESS_REDIS,    value: "redis://redis:6379" }
  - { name: PAPERLESS_DBHOST,   value: "postgres" }
  - { name: PAPERLESS_DBNAME,   value: "paperless" }
  - { name: PAPERLESS_DBUSER,   value: "paperless" }
  # PAPERLESS_DBPASS, PAPERLESS_SECRET_KEY, PAPERLESS_ADMIN_* from the SealedSecret
  - { name: PAPERLESS_URL,               value: "https://paperless.henrydowd.dev" }
  - { name: PAPERLESS_ALLOWED_HOSTS,     value: "paperless.henrydowd.dev,paperless.lan" }
  - { name: PAPERLESS_CSRF_TRUSTED_ORIGINS, value: "https://paperless.henrydowd.dev" }
  - { name: PAPERLESS_CORS_ALLOWED_HOSTS,   value: "https://paperless.henrydowd.dev" }
  # LOAD-BEARING: Cloudflare terminates TLS, cloudflared→Traefik is plain HTTP,
  # so Django sees http and will refuse secure cookies / build http:// callbacks
  # / redirect-loop the login. This tells it to trust X-Forwarded-Proto.
  - { name: PAPERLESS_PROXY_SSL_HEADER,  value: '["HTTP_X_FORWARDED_PROTO","https"]' }
  - { name: PAPERLESS_TRUSTED_PROXIES,   value: "10.42.0.0/16" }   # pod CIDR — trust XFF from Traefik
  - { name: PAPERLESS_OCR_LANGUAGE,      value: "eng" }
  - { name: PAPERLESS_TIME_ZONE,         value: "Europe/Dublin" }
  - { name: PAPERLESS_WEBSERVER_WORKERS, value: "2" }
  - { name: PAPERLESS_TASK_WORKERS,      value: "1" }
  - { name: PAPERLESS_THREADS_PER_WORKER, value: "1" }
  ```

- `service.yaml` — port 8000.
- `ingress.yaml` — `paperless.lan` + `paperless.henrydowd.dev`,
  `ingressClassName: traefik`, no entrypoints annotation, no `tls:` block.
- `networkpolicy.yaml` — default-deny-**ingress** only (copy `kiwix`, port
  8000). DB/redis are same-namespace so they need no allow rule; **do not** add
  a restrictive egress netpol — Paperless' consumer/workers hit Postgres at
  t≈0 and would trip the kube-router fresh-pod race that broke nextcloud-cron.

---

## Step 3: first run + OCR smoke test

```bash
argocd app get paperless --grpc-web       # Synced/Healthy
kubectl -n paperless logs deploy/paperless -f    # watch migrations, then "Created superuser"
```

Log in at `https://paperless.henrydowd.dev` as the bootstrap admin. Prove the
pipeline end to end:

```bash
# drop a test PDF into the watched consume folder
kubectl -n paperless cp ~/some-invoice.pdf paperless-<pod>:/usr/src/paperless/consume/
```

Watch the logs OCR it, tag it, and index it; confirm it appears in the UI and
that **full-text search** finds a word from inside the document (proves OCR +
the search index, not just the upload). Do not proceed until a consumed
document is searchable.

Re-verify Longhorn volumes healthy — you just added **four** PVCs, exactly the
condition the replica-drift gotcha warns about
(`kubectl -n longhorn-system get volumes.longhorn.io` all `healthy`, 1 replica).

---

## Step 4: OIDC via Authelia (after phase 8)

Register a `paperless` client in the Authelia ConfigMap (add it to that plan's
step-5 client table), redirect URI
`https://paperless.henrydowd.dev/accounts/oidc/authelia/login/callback`. Add
the client secret to the `paperless-secrets` SealedSecret, then enable
django-allauth's OIDC provider via env:

```yaml
- { name: PAPERLESS_APPS, value: "allauth.socialaccount.providers.openid_connect" }
- name: PAPERLESS_SOCIALACCOUNT_PROVIDERS
  value: >
    {"openid_connect":{"APPS":[{"provider_id":"authelia","name":"Authelia",
    "client_id":"paperless","secret":"<from-secret>",
    "settings":{"server_url":"https://auth.henrydowd.dev"}}]}}
```

Log in as the existing admin first, then link the Authelia identity under the
profile so it maps to your user rather than creating a duplicate (or set
`PAPERLESS_SOCIAL_ACCOUNT_DEFAULT_GROUPS`). Keep native login enabled until the
web + Paperless Mobile app are both proven against OIDC.

---

## Step 5: backup (restic → B2)

New repo `.../paperless`. Media files are immutable once ingested and Postgres
`pg_dump` is hot-safe, so **no scale-to-0** (unlike Gitea) — model it on the
Immich/Nextcloud cronjob:

- `backup-sealed-secret.yaml` — `backup-credentials` with `RESTIC_REPOSITORY`
  (`s3:https://…/paperless` — the `s3:https://` prefix is load-bearing, restic
  gotcha), `RESTIC_PASSWORD`, B2 keys.
- `backup-cronjob.yaml` — 04:30 (staggered after immich 04:00), `podAffinity`
  co-locating on the worker (RWO `media` mount), `pg_dump` to an emptyDir +
  `restic backup` the emptyDir dump **and** the `media` PVC mounted read-only
  (no downtime). Retention 7d/4w/3m. No backup-rbac (no scaling).
- **Periodically** (or as a second, weekly cron) run Paperless' own
  `document_exporter ../export` — it writes a portable `manifest.json` +
  originals that `document_importer` restores across version/schema changes,
  insurance a raw PG-dump+media-tar can't give on a major Paperless upgrade.

Add the repo + a test-restore row to `restore-procedure.md`. `RESTIC_PASSWORD`
to the password manager (loss = permanent loss of the document archive).

---

## Step 6: aftercare

- **Docs**: `services.md` (+ Paperless row, auth = OIDC-after-8), HOMELAB.md
  (never commit), `adding-a-service` runbook already covers ingress/netpol.
  `public-export-checklist` — Paperless holds household documents; the sealed
  secret is safe in git, real documents live only on the PVC, never in the repo
  or image (same discipline as file-parser).
- **Capacity**: measure resident with the OCR queue idle vs. mid-ingest and
  record both in `capacity-headroom.md` — the burst is what gates the worker.
- **Monitoring**: Paperless exposes no Prometheus metrics by default (no
  django-prometheus in the image) — skip a VMServiceScrape; a follow-up could
  add a blackbox `up` probe on `/` if an outage alert matters.
- **Optional consume integration**: point a Nextcloud external-storage folder
  (or a group folder) at the `consume` PVC so a scan dropped into Nextcloud
  auto-ingests — nice, but a later follow-up, not bring-up.

## Failure modes

- `PAPERLESS_PROXY_SSL_HEADER` missing ⇒ login over the tunnel redirect-loops
  or 403s CSRF (Django thinks it's on http). The single most likely bring-up
  failure — same class as the Proxmox secure-cookie / Immich trusted-proxy
  gotchas.
- A huge scan OCR-OOMs the worker ⇒ raise the limit or lower
  `TASK_WORKERS`/`THREADS_PER_WORKER` (peak scales with the document, the
  file-parser large-PDF lesson).
- Valkey restart ⇒ an in-flight consume task is lost; re-drop the file
  (queue is not persisted, by design).
- Migrations on a version bump take minutes ⇒ the startupProbe grace is what
  keeps k8s from killing the pod mid-migration.
