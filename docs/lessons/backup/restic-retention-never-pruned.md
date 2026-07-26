# Incident: restic retention never deleted a single snapshot — every snapshot was its own retention group

## Date
2026-07-26 (dormant since the CronJobs were created, 2026-06-05 onward)

## Time lost
None in outage terms; nothing broke. ~1h to find and fix, discovered incidentally while
clearing an unrelated alert. The cost was silent: ~51 days of unpruned snapshots in B2
across three repos.

## Status
Resolved in the manifests (commit `c1b81b3`). The first real prune runs on tonight's
schedule, so the snapshot counts below are still live until then.

## Context
- **System / component:** the three restic→B2 backup CronJobs, `nextcloud-backup`,
  `gitea-backup`, `immich-backup`.
- **Scope:** every repo, every run, since each CronJob was created.
- **State before:** normal. Backups running nightly, all reporting success, and cited as
  healthy in `docs/reference/known-risks.md` §8 two days earlier.

## Symptoms

There were none, which is the whole problem. Every job exited 0, every job logged its
`[backup] Pruning old snapshots...` line, and `restic snapshots` showed a clean unbroken
daily series. Nothing alerted, nothing failed, and the repos were being *described* as
healthy on the strength of exactly the number that was the evidence of the bug.

The only visible tell is snapshot count against CronJob age, and it only looks wrong if you
know the retention policy is `--keep-daily 7 --keep-weekly 4 --keep-monthly 3`, so roughly
12–14 snapshots per tag at steady state:

| Repo | Tags | Snapshots | CronJob age | Expected |
|---|---|---|---|---|
| gitea | 1 | 55 | 51d | ~12 |
| immich | 2 | 90 | 44d | ~24 |
| nextcloud | 2 | 104 | 51d | ~24 |

One snapshot per tag per day since creation, retained in full. Nothing had ever been
deleted.

## Investigation

This was found sideways. The starting point was two stale `BackupJobFailed` criticals left
over from the Longhorn incident, and the intent was only to confirm the backups had really
landed in B2 rather than trusting the jobs' exit codes.

- **Confirmed the backups were genuinely fine.** All three repos hold a real 2026-07-26
  snapshot. This mattered before touching anything else, and it is also what turned a
  five-minute check into this.
- **Hyp 1: a stale lock is blocking prune.** Partly true, and it is the trap. The nextcloud
  repo held a lock dated six weeks earlier:
  ```text
  {
    "time": "2026-06-12T01:51:07Z",
    "exclusive": false,
    "hostname": "restic-compare-nc",
    "username": "root",
    "pid": 15
  }
  ```
  Left by a manual comparison pod that no longer exists. restic only treats a lock as stale
  if it is older than 30 minutes *and* it can confirm the owning process is gone, which it
  can only do when the lock's hostname matches the host checking it. A lock written by a
  since-deleted pod therefore never expires on its own, and it silently blocks every
  `--prune` in that repo.
- **Hyp 1 ruled out as *the* cause.** gitea and immich had **no** locks at all and were
  equally unpruned. A lock cannot explain a repo with no lock in it. Worth stating because
  clearing the lock and walking away would have left the actual bug in place and looked like
  a fix.
- **Hyp 2: prune errors were being swallowed.** True, and it explains the silence, not the
  behaviour. nextcloud and immich both end their forget lines with `|| true`:
  ```bash
  restic forget --keep-daily 7 --keep-weekly 4 --keep-monthly 3 \
    --prune --tag nextcloud-data || true
  ```
  So the nextcloud lock error could never fail a job. But `gitea-backup` has no `|| true`,
  its forget would have failed the job loudly, it never did, and gitea was still unpruned.
  That is what rules out "prune is erroring" entirely and points at prune succeeding while
  choosing to delete nothing.
- **Confirmed mechanism.** Read the hostname column of the snapshot listing:
  ```text
  ee0dd1e7  2026-07-24 02:30:44  gitea-backup-29747670-jj974  gitea-data  /data
  4083ace5  2026-07-25 02:30:41  gitea-backup-29749110-2gdwb  gitea-data  /data
  9e1c132a  2026-07-26 10:38:09  gitea-backup-29750550-vmwjs  gitea-data  /data
  ```
  Every snapshot has a different hostname, because restic takes it from `os.Hostname()` and
  a Kubernetes pod's hostname defaults to the pod name, which carries the CronJob's schedule
  hash and a random suffix. Every run is a new host as far as restic is concerned.

## Root cause

`restic forget` defaults to `--group-by host,paths`. It buckets snapshots by that key and
then applies the `--keep-*` policy **independently within each bucket**.

Because the hostname is the pod name and unique per run, every snapshot landed in a bucket
of its own. `--keep-daily 7` applied to a group containing exactly one snapshot keeps that
snapshot. Repeat for all 55, and forget correctly reports success having deleted nothing.

The policy was never wrong and prune was never broken. The *grouping* silently made the
policy a no-op, and it fails in the safe direction, which is precisely why it survived 51
days, a documented quarterly restore test, and a risk review that read the inflated snapshot
count as evidence of health.

The stale nextcloud lock is a genuine second defect that would have blocked prune in that
repo the moment the grouping was fixed. Either one alone is sufficient to stop retention;
both were present in nextcloud.

## Fix

`--group-by tags` on every forget, in all three CronJobs (commit `c1b81b3`). Each forget is
already filtered to a single `--tag`, so grouping by tag collapses the whole series into one
group and the keep policy means what it says:

```bash
restic forget \
  --group-by tags \
  --keep-daily 7 \
  --keep-weekly 4 \
  --keep-monthly 3 \
  --prune \
  --tag gitea-data
```

The stale lock, cleared with no backup running:

```bash
restic unlock --remove-all
# successfully removed 1 locks
```

`--remove-all` is required rather than a plain `restic unlock`, which only removes locks it
can prove are stale and will therefore not touch a foreign-hostname lock like this one.

## Verification

Dry-run against the live gitea repo before committing, which is the check that proves the
grouping was the cause rather than assuming it:

```bash
restic forget --group-by tags --keep-daily 7 --keep-weekly 4 --keep-monthly 3 \
  --tag gitea-data --dry-run
# 43 snapshots would be removed, 12 kept
```

12 kept matches the documented 7d/4w/3m policy. Locks empty in all three repos afterwards,
and the 2026-07-26 snapshot present in each.

Not yet verified: the first prune has not run. Confirm after tonight's schedule that counts
have actually dropped and that `--prune` completed rather than erroring behind a `|| true`:

```bash
restic snapshots --no-lock | tail -3     # expect ~12 per tag, not ~55
restic list locks --no-lock              # expect empty
```

## Prevention

- **Drop the `|| true` on the nextcloud and immich forget lines, or narrow it.** It was
  added so a prune failure could not fail an otherwise-good backup, which is reasonable, but
  as written it also swallows the signal permanently. gitea's unguarded version is the
  reason this was diagnosable at all.
- **Alert on repo growth, not job exit code.** Nothing here would have been caught by any
  existing rule, because the failure mode is a job succeeding at doing nothing. A check on
  snapshot count per tag, or on B2 bucket size trending monotonically up, is the honest
  detector.
- **B2 lifecycle is still unset.** Already tracked as an open action; until the bucket is set
  to keep only the last version, `--prune` removes pack files from the repo without actually
  freeing the storage, so tonight's prune will not shrink the bill on its own.
- **Beware any restic invocation from a pod.** Anything that runs restic with a
  pod-generated hostname inherits this. `--host` on `restic backup` would give stable
  hostnames going forward, but it would not have retroactively regrouped the existing
  snapshots, which is why the fix went on `forget` instead.

## Related
- Found while clearing alerts from: `docs/lessons/storage/longhorn-autosalvage-blocked-diskpressure.md`
- Same shape, a retention job that ran nightly and silently pruned nothing:
  `docs/lessons/storage/zfs-snapshot-retention-noop.md`
- Backup posture and the restore-test cadence: `docs/reference/known-risks.md` §8
- Alert that was firing when this was found (`BackupJobFailed` counting pod attempts, fixed
  in the same commit): `k8s/apps/monitoring/homelab-rules.yaml`
