# ADR 004 — Offsite backups with restic to Backblaze B2

**Status:** Accepted
**Date:** 2026-06

## What problem this solves

After Nextcloud and Gitea moved into the cluster, every copy of irreplaceable
data lived inside one machine. Longhorn was set to replica count 1 (because
there's only one worker), and the pre-migration ZFS snapshot lived on the same
two physical disks. RAID-1 handles a single disk failing. It doesn't handle
the machine being stolen, a fire, ransomware, or me running the wrong
`zfs destroy`. Until there was an offsite copy, the migrated LXCs couldn't be
torn down either — they were the last independent backup.

So the goal: a copy of the important data that's outside the house, encrypted,
and survives me typing the wrong command.

## What we picked

Per-service CronJobs that push to Backblaze B2 using restic over its
S3-compatible endpoint. Each service has its own restic repository under a
single shared bucket (`hpd.homelab/nextcloud`, `hpd.homelab/gitea`). Separate
repos mean a Nextcloud restore doesn't have to touch Gitea data and vice versa.

A few quick notes on each:

- **Nextcloud** runs alongside the live pod. `podAffinity` schedules the
  backup pod on the same node, which is the only way to mount a Longhorn RWO
  volume "read-only on the side" without detaching it from the running app.
  The Postgres DB gets `pg_dump`'d into an emptyDir and backed up as its own
  tagged snapshot — file data and DB are restored independently.
- **Gitea** takes the opposite approach: scale the Deployment to 0, mount
  the volume, back up, scale back to 1. Gitea uses SQLite, and a hot copy of
  a SQLite file is a recipe for a torn read. A few minutes of downtime at
  3:30am is fine. There's a shell `trap` so even if restic crashes, Gitea
  comes back up.
- **Flaky uploads.** The link here is a consumer connection that drops mid-
  transfer once in a while, especially during the initial 37GB Nextcloud seed.
  restic uploads pack files and tracks what's already in the repo, so a re-run
  picks up where the last one died. The Nextcloud job wraps `restic backup`
  in a retry loop and lowers `s3.connections` to 2 — both small things that
  add up to "the seed actually finished".

## What I considered and didn't pick

- **Longhorn's built-in S3 backup.** Volume-level snapshot. Simpler, but it's
  crash-consistent, not application-consistent — restoring a half-written
  Postgres data dir is a bad time. Kept as a secondary safety net via
  Longhorn's local scheduled snapshots, just not the primary offsite path.
- **`gitea dump`.** Gitea's blessed backup command. Two problems: it expects
  Gitea to be down for a consistent dump anyway (so no downtime saved), and
  each run produces a fresh ZIP. restic can't dedupe across ZIPs the way it
  can across a raw filesystem, so daily retention gets expensive fast. The
  one downside of the raw-volume approach — needing to run
  `gitea admin regenerate hooks` after a restore — is documented in the
  restore runbook.
- **Velero.** Full cluster-backup tool. Overkill for two services. Worth
  revisiting if there are more apps.
- **AWS S3.** Same restic config, slightly more annoying signup, slightly
  pricier. B2 is the cheap version of the same thing.

## Consequences I should remember

- Data is encrypted with AES-256 and deduplicated on the cluster before
  leaving. B2 only ever sees ciphertext.
- **Losing `RESTIC_PASSWORD` = the backups are forever gone.** That password
  is in my password manager, *not* in the cluster, so a cluster rebuild
  doesn't take it with it.
- It costs about $0.13/month at current size. Uploads are free, and a "ratio"
  amount of egress is also free, so test-restores aren't an expensive event.
- The B2 bucket lifecycle has to be set to "keep only the last version of the
  file". Without that, `restic forget --prune` only deletes the *current*
  pointer; old versions accumulate invisibly and storage usage creeps up
  forever.
- A backup that hasn't been restored isn't really a backup. See
  `docs/restore-procedure.md` for the procedure and the table tracking when
  I last actually did a test restore.
