# ADR 015: Paperless-ngx document archive

**Status:** Accepted
**Date:** 2026-07-23

## What problem this solves

Household paper — invoices, statements, letters, warranties — currently lives
as loose scans with no OCR, no full-text search, and no consistent backup.
Paperless-ngx turns the pile into a searchable archive: it OCRs each document
on ingest, indexes the text, and holds the originals as immutable files. The
walkthrough is `docs/plans/phase-10-paperless-ngx.md`; this ADR records the
decisions that plan assumes.

## What I picked

**Paperless-ngx v3.0.0, three pods in the Immich shape.** One app image runs
gunicorn, the Celery task workers, and the consumer together under
supervisord; a dedicated Postgres and a Valkey broker sit beside it.

| Decision | Choice | Why |
|---|---|---|
| Version | **v3.0.0** (pinned) | Newest major (Tantivy search backend, released 2026-07-22). Chosen over the mature v2.20.15 despite being a day-old x.0.0 — accepted risk, mitigated by backups from day one and keeping password login. |
| DB | **Postgres 18** (own Deployment) | Concurrent OCR workers + full-text search deadlock SQLite under Celery. PG18 is what the v3.0.0 compose pairs (v2.x paired PG17). |
| Broker | **Valkey 9, no persistence** | Queue/result cache only; a restart just re-runs an in-flight consume. |
| Office/email ingest | **excluded** (no Tika/Gotenberg) | Those two sidecars cost ~300–400Mi against the tight worker; OCR alone covers PDFs + scanned images, which is the household's paper. Add them later if `.docx/.eml` ingest is actually wanted. |
| Storage | Longhorn PVCs: `data` 5Gi · `media` 20Gi · `consume` 1Gi · `db` 10Gi | `media` holds the irreplaceable originals + OCR'd archive and grows online (Longhorn can't shrink). |
| OCR language | `eng` | Add `deu`/`fra`… via `PAPERLESS_OCR_LANGUAGES` (apt packs) if ever needed. |
| Concurrency | `WEBSERVER_WORKERS=2`, `TASK_WORKERS=1`, `THREADS_PER_WORKER=1` | OCR is RAM-bursty and the worker peak already touches ~2.7Gi free; cap OCR to fit and accept slower bulk ingest. |
| Auth | **native now; Authelia OIDC after phase 8** | Paperless Mobile hits `/api` directly, so it's an OIDC client, not ForwardAuth (per the phase-8 plan). Native login stays even after OIDC lands. |
| Exposure | `paperless.lan` + `paperless.henrydowd.dev`, public via tunnel | Sensitive documents — same data-handling class as file-parser; sealed secret is git-safe, real documents live only on the PVC. |
| Backup | restic → B2 (new repo) — `pg_dump` + read-only `media` mount, plus periodic `document_exporter` | Media files are immutable once ingested and `pg_dump` is hot-safe, so no scale-to-0 (unlike Gitea). |

## What I rejected

- **v2.20.15 (last 2.x).** The conservative pin — mature, matches the plan's
  original PG17 assumption. Rejected in favour of starting on the v3 line so
  the archive isn't built on a version that's already a major behind; the
  x.0.0 risk is bounded because nothing irreplaceable exists until documents
  are ingested, and backups + `document_exporter` are in from day one.
- **SQLite.** Simpler (one fewer pod), but Celery's concurrent OCR + FTS
  writes lock it. Postgres is the documented production path.
- **Tika + Gotenberg sidecars** for Office/email ingest. Real feature, but
  ~300–400Mi steady against the worker's already-thin peak headroom
  (`docs/reference/capacity-headroom.md`), for document types the household
  barely produces. Deferred, not refused.
- **ForwardAuth via Authelia** (once phase 8 exists). Would break Paperless
  Mobile, which talks to `/api` without a browser. OIDC is the correct tier —
  recorded here and in the phase-8 client table.
- **Backing up derivatives / scale-to-0 backup.** The `archive`/thumbnail
  derivatives regenerate from originals; only originals + DB need saving. And
  `pg_dump` is hot-safe, so the backup runs alongside the live pod (Immich
  pattern), no downtime.

## Consequences

- **Three more pods on the worker.** ~0.8–1.1Gi steady, ~1.5–1.8Gi during an
  OCR burst (limit capped at 1.5Gi). Fits current headroom (~3.9Gi free
  idle), but a big-scan OCR burst *concurrent with* an Immich ML import could
  approach the `NodeMemoryLowWorker` 2Gi floor — the two bursts are both
  user-triggered, so stagger the initial bulk ingest away from Immich imports
  and watch `MemAvailable` through the first large scan.
- **The reverse-proxy env set is load-bearing.** Cloudflare terminates TLS and
  cloudflared→Traefik is plain HTTP, so Django must be told to trust
  `X-Forwarded-Proto` (`PAPERLESS_PROXY_SSL_HEADER` + `TRUSTED_PROXIES`) or
  login redirect-loops / 403s CSRF over the tunnel. Same class as the Proxmox
  secure-cookie and Immich trusted-proxy gotchas.
- **Losing the archive is permanent.** `PAPERLESS_SECRET_KEY` and the restic
  `RESTIC_PASSWORD` go to the password manager; the documents live only on the
  `media` PVC + B2. `document_exporter` is the version-portable insurance a
  raw pg_dump+media-tar can't give across a major Paperless upgrade.
- **v3.0.0 is new** — watch the release tracker for a fast-follow patch and be
  ready to bump. The DB is small; a migration on a version bump is minutes,
  which the generous startupProbe grace absorbs.
- **Started on native auth.** OIDC is a follow-up (phase-8 step 4); until then
  the bootstrap admin + password login is the only gate, behind the tunnel.

## Related

- docs/plans/phase-10-paperless-ngx.md — the full bring-up walkthrough
- docs/plans/phase-8-authelia.md — OIDC client registration (step 5) added later
- docs/reference/capacity-headroom.md — the worker RAM budget this fits into
- Manifests: k8s/apps/paperless/
