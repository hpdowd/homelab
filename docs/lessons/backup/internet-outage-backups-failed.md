# Incident: an ISP outage over the backup window failed all four nightly backups

## Date
2026-10-20

## Time lost
~1h (diagnosis, re-runs, cleanup). One night of backups missed across all four
repos; no data lost, and every repo has a fresh snapshot the same day.

## Status
Resolved. Prevention proposed below, not yet implemented.

## Context
- **System / component:** the four restic→B2 backup CronJobs (`nextcloud`,
  `gitea`, `immich`, `paperless`) and the home internet link
- **Scope:** every backup on the cluster for one night. Apps unaffected.
- **State before:** idle overnight. The ISP link dropped twice on 2026-10-20,
  roughly **00:10–08:05 UTC** and **12:00–15:25 UTC**. The schedules are
  03:00 / 03:30 / 04:00 / 04:30 `Europe/Dublin`, i.e. 02:00–03:30 UTC (IST), so
  the whole backup window sat inside the first outage with hours to spare on
  either side.

## Symptoms
Twelve backup alerts on top of the three standing ones (`Watchdog`,
`KubeCPUOvercommit`, `KubeMemoryOvercommit`):

| Alert | Namespaces | Fired (UTC) |
|---|---|---|
| `BackupJobFailed` (critical) | all four | 02:12, 02:32, 03:13, 03:42 |
| `KubeJobFailed` (warning) | all four | 15 min after each of the above |
| `BackupJobMissing` (critical) | all four | 05:07–06:31, i.e. 26h + `for: 1h` after the 2026-10-19 runs |

`BackupJobMissing` is the same missed night crossing its 26h threshold.

None of these could be *delivered* while the link was down. Alertmanager's email
(Brevo SMTP), Pushover and the healthchecks.io deadman all need DNS for an
external name, and all three failed until the link came back, so the first
notification arrived hours after the failures.

## Investigation
- **Cluster health first.** Both nodes `Ready`, no non-`Running` pods outside
  completed Jobs, every app Deployment 1/1. Not a cluster problem.
- **Job logs: gone.** The failed Jobs had no pods
  left to read. All four CronJobs use `restartPolicy: OnFailure`, so retries
  restart the container *inside one pod*. When `backoffLimit` is exceeded, the
  Job controller deletes that pod, and the logs go with it. All that survives is
  `reason: BackoffLimitExceeded` on the Job. Everything below is reconstructed
  from other sources.
- **Where's the repo?** `RESTIC_REPOSITORY` is
  `s3:https://s3.eu-central-003.backblazeb2.com/...`, so every backup needs the
  internet. Combined with the reported outages, that is the obvious hypothesis.
  It needed confirming, because "the internet was down at some point today" does
  not mean it was down from 02:00 to 03:40.
- **Bracketing the outage.** Three independent clocks agreed:
  - **Alertmanager notify failures** are the sharpest. Bucketed per 10 minutes,
    errors start at `00:1x`, run continuously to `08:0x`, stop, then resume
    `12:0x`–`15:2x`. They are all DNS failures through CoreDNS:
    ```text
    dial tcp: lookup smtp-relay.brevo.com on 10.43.0.10:53: server misbehaving
    dial tcp: lookup hc-ping.com on 10.43.0.10:53: server misbehaving
    dial tcp: lookup api.pushover.net on 10.43.0.10:53: server misbehaving
    ```
  - **chrony on `pve`**: `Can't synchronise: no selectable sources (4
    unreachable sources)` at 03:51, a source reselected at 09:16. A lagging
    indicator: chrony takes a while to give up on sources. It brackets the window
    but understates the start.
  - **The ddns log in LXC 101** (only writes on change): no change from
    2026-10-19 02:10 until a new WAN IP at 08:05, and another at 15:30, matching
    the end of each outage. Same tell as in the power-cuts lesson: the router
    re-IPs when the link comes back.
- **Failure times**, from `kube_job_status_failed` in VictoriaMetrics: nextcloud
  02:11, gitea 02:31, immich 03:12, paperless 03:40 UTC. Each Job was dead about
  11 minutes after it started (gitea after 1.5). Every retry budget was spent
  inside an outage that lasted eight hours.
- **Where each script died (inferred from the scripts and the timing, not from
  logs).** The first network call in all four is
  `apk add --no-cache restic` (plus `curl` for gitea) against
  `dl-cdn.alpinelinux.org`, before anything touches B2:
  - **gitea** runs `set -euo pipefail`. `apk add` fails and the script exits
    straight away, *before* the `trap ERR` and the scale-to-0. Gitea was never
    taken down. Two attempts (`backoffLimit: 1`) in ~1.5 min.
  - **nextcloud / immich / paperless** run `set -uo pipefail`, with no `-e` on
    purpose so the retry loops can work. `apk add` fails silently, `pg_dump`
    succeeds (it is in-cluster), and then the restic retry loop retries a binary
    that was never installed: 8 × `restic: not found` + `sleep 20`, so
    ~3 min, then `exit 1`. With `backoffLimit: 3` and the kubelet's restart
    backoff, four attempts come to ~11 min, which matches the observed failure
    times. The retry loops were built for flaky *uploads*. They cannot help when
    the install step has already failed.
- **Is it over?** `curl https://s3.eu-central-003.backblazeb2.com/` from
  `control-node` returned 403 (unauthenticated, which is expected) in 0.09s.
  The link is back.

## Root cause
The internet was down for the whole backup window, and the backups need it
twice: once for `apk add restic`, once for B2. Every Job's retry budget is
measured in minutes (≤ ~12), against an outage measured in hours, so no retry
could have outlasted it. Nothing was misconfigured. This is the expected outcome
of a nightly job that has no catch-up.

## Fix
Re-ran every backup by hand and removed the failed Jobs:

```bash
ssh control-node '
for ns in nextcloud gitea immich paperless; do
  kubectl -n $ns create job --from=cronjob/$ns-backup $ns-backup-manual-$(date +%s)
done
kubectl -n nextcloud delete job nextcloud-backup-29874360
kubectl -n gitea     delete job gitea-backup-29874390
kubectl -n immich    delete job immich-backup-29874420
kubectl -n paperless delete job paperless-backup-29874450'
```

The failed Jobs have to be deleted by hand. `BackupJobMissing` clears on
its own once a backup succeeds, but `BackupJobFailed` and `KubeJobFailed` key on
the failed Job object. `failedJobsHistoryLimit` only evicts it when a *newer*
failure arrives, and the backup CronJobs deliberately carry no
`ttlSecondsAfterFinished`. Left alone, they would have alerted indefinitely (see
`docs/lessons/k8s/kubejobfailed-isolated-failure-never-evicted.md`). No logs were
lost by deleting them: their pods were already gone.

## Verification
```bash
# all four manual Jobs → Complete; each log ends with a 2026-10-20 snapshot:
#   nextcloud-data 24.947 GiB + nextcloud-db   immich-data 26.285 GiB + immich-db
#   gitea-data                                 paperless-media + paperless-db
ssh control-node 'kubectl -n gitea rollout status deploy/gitea'   # scaled back, 1/1
# Alertmanager active alerts → Watchdog, KubeCPUOvercommit, KubeMemoryOvercommit only
```

## Prevention
A missed night is a one-snapshot gap in a 7d/4w/3m retention and every alert
was correct, so most of this is accepted risk. Three cheap improvements, none
applied yet:

1. **`restartPolicy: Never` on the backup Jobs.** Each retry becomes its own
   pod, and failed pods are retained with the Job, so the next failure leaves its
   logs behind. This incident's diagnosis had to be reconstructed from three
   indirect sources because the one direct source had been deleted. Highest
   value, smallest change.
2. **Stop installing restic at runtime.** `apk add` is a second internet
   dependency, and in the no-`-e` scripts its failure is silent and surfaces as a
   misleading `restic: not found` ×8. Either use an image that ships restic, or
   at least fail fast with a clear message when `apk add` fails.
3. **Optionally, wait out short outages.** A pre-flight loop that polls B2 (for
   example every 5 min for up to 2h) before doing any work would have ridden out
   a shorter drop. For gitea it **must** run before the scale-to-0, or a long
   outage turns into Gitea downtime. It would not have saved this night, which
   was 8h, so this is lower value than 1–2.

Re-running is manual and takes about 15 minutes (immich is the long one). It
scales Gitea down for ~1.5 min.

## Related
- Lessons: `docs/lessons/k8s/kubejobfailed-isolated-failure-never-evicted.md` (why the failed Jobs had to be deleted)
- Lessons: `docs/lessons/infra/power-cuts-host-stayed-off.md` (the ddns log as a record of when the link or router dropped)
- Lessons: `docs/lessons/backup/paperless-backup-unmonitored.md` (why all four namespaces alerted, not three)
- ADR: `docs/adr/004-restic-b2-bckup.md`, `docs/adr/019-pushover-critical-alerts.md`
- Runbook: `docs/runbooks/backup-verification.md`
