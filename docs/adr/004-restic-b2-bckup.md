# ADR 004 — Offsite Backup via restic + Backblaze B2

**Status:** Accepted
**Date:** 2026-06

## Context

After migrating Nextcloud and Gitea into the k3s cluster, the only copies of
irreplaceable user data lived on a single Longhorn replica (replica count = 1,
single worker node) plus a ZFS `@pre-migration` snapshot on the *same physical
disks*. RAID-1 protects against a single disk failure but not against machine
loss, theft, fire, ransomware, or operator error. This was the highest-priority
gap in the infrastructure and blocked decommissioning the migrated LXCs.

## Decision

Use per-service restic CronJobs that back up to Backblaze B2 via the
S3-compatible API. Each service's job runs in its own namespace so it can mount
the service PVC directly; each service has its own restic repository path within
a shared bucket (`hpd.homelab/nextcloud`, `hpd.homelab/gitea`).

- **Nextcloud:** co-locates with the running pod via podAffinity and mounts the
  data PVC read-only (no downtime); the Postgres DB is captured with `pg_dump`
  to a custom-format dump that is backed up alongside the file data.
- **Gitea:** scales the Deployment to 0 before backup (Longhorn RWO volumes only
  permit single-pod attachment), backs up the /data volume, then scales back up.
  Scale operations use the Kubernetes API via the mounted service account token
  (no kubectl binary), guarded by a `trap` so the Deployment is restored even if
  the backup fails.
- **Resilience:** the Nextcloud job wraps `restic backup` in a retry loop with
  reduced S3 connection concurrency, tolerating the connection drops typical of a
  consumer upload link. restic resumes from the repo index across attempts, so
  retries make forward progress rather than restarting.

## Alternatives considered

- **Longhorn recurring backup to S3:** volume-level, crash-consistent. Simpler but
  not application-consistent and coupled to Longhorn. Kept as a secondary layer
  via Longhorn's scheduled snapshots.
- **`gitea dump`:** Gitea's official method. Rejected as the *primary* mechanism
  because the official docs require shutting Gitea down for a consistent dump
  anyway (so it saves no downtime over the scale-down approach), and each dump is
  a fresh ZIP that restic cannot deduplicate — making daily retention far more
  expensive than a raw-volume backup. The raw-volume restore's one extra step
  (`gitea admin regenerate hooks`) is documented in the restore procedure.
- **Velero:** full cluster backup tooling, heavier than needed for two services.
  Revisit if the cluster grows.
- **AWS S3:** more resume-relevant but brittle signup experience and pricier;
  same restic config. Revisit for deliberate AWS exposure later.

## Consequences

- Data is encrypted (restic AES-256) and deduplicated client-side before leaving
  the cluster; B2 never sees plaintext.
- **RESTIC_PASSWORD loss = permanent data loss.** Stored in password manager,
  outside the cluster, so it survives a cluster rebuild.
- Cost is negligible (~$0.13/month at current data size); uploads and in-ratio
  egress are free.
- B2 bucket lifecycle must be set to "Keep only the last version of the file" so
  `restic forget --prune` translates into actual storage reclamation rather than
  hidden versions accumulating.
- A backup is only trustworthy once a restore is verified — see restore-procedure.md
  for the testing cadence.
