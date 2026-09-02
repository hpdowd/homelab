# Incident: paperless backups ran unmonitored for 25 days

## Date
2026-08-18 (found); gap opened 2026-07-24, first bit 2026-07-26

## Time lost
~1h to find and fix. The cost was risk, not downtime, see below.

## Status
Resolved

## Context
- **System / component:** `monitoring` namespace, `homelab-rules` VMRule, `homelab.backups` group
- **Scope:** the `paperless` nightly restic→B2 CronJob had no alerting on it at all
- **State before:** everything green. Nothing was broken, which is the point

## Symptoms
There were none. That is the whole incident.

`BackupJobFailed` and `BackupJobMissing` both carried a hardcoded namespace
filter:

```promql
kube_job_status_failed{namespace=~"nextcloud|gitea|immich", job_name=~".*backup.*"} > 0
```

Paperless went live 2026-07-23 (HOMELAB.md phase 10, ADR 015) with a backup
CronJob "from day one". The rule was never widened to match. Every other place
that tracks backup coverage *was* updated, which is what made it invisible:

- `docs/runbooks/backup-verification.md` loops `for ns in nextcloud gitea immich paperless`
- `docs/runbooks/restore-procedure.md` documents restoring Paperless
- ADR 015 specifies restic→B2 with `document_exporter` insurance

So every human-facing artefact said paperless was backed up and verified, and
it genuinely was being backed up. Only the thing that would tell you when it
*stopped* had been missed.

## Investigation
Started from the other end: checked what was firing, not what wasn't.

- Three alerts firing: `Watchdog`, `KubeCPUOvercommit`, `KubeMemoryOvercommit`.
  All three already null-routed on purpose in `victoria-metrics.yaml` ("fire
  permanently on a 2-node cluster, true by design here"). Verified the maths
  rather than trusting the comment: memory requests 6.44G against
  allocatable-minus-largest-node 5.09G = 1.349G, exactly the alert's value.
  Not a bug. → dead end, correctly.
- All 261 loaded rules `health=ok`, no `lastError`, all 15 homelab rules
  present and evaluating. No down scrape targets (`up == 0` empty).
  So nothing was broken *in* the alerting pipeline.
- Which left the opposite question: what is running that nothing watches?
  `kubectl get cronjob -A` lists five backup-ish jobs; the rule regex covers
  three of them.

Then checked whether the gap had ever actually mattered, rather than assuming:

```promql
max by (namespace) (kube_job_status_failed{job_name=~".*backup.*"})   # over 30d
```

```text
gitea:     64 hourly points failed>0, 2026-07-26T11:00Z → 2026-07-29T02:00Z
immich:    65 hourly points failed>0, 2026-07-26T11:00Z → 2026-07-29T03:00Z
paperless:  3 hourly points failed>0, 2026-07-26T08:00Z → 2026-07-26T10:00Z
nextcloud: no failures in window
```

2026-07-26 is the Longhorn auto-salvage outage. It failed backup jobs in three
namespaces. gitea and immich raised `BackupJobFailed` and stayed stale for three
days, which is what led to finding the restic retention no-op. **Paperless
failed in the same event and said nothing.** It was noticed only sideways,
because ArgoCD independently showed the namespace `Degraded` on a CronJob
timestamp comparison, and got a manual recovery run
(`paperless-backup-manual-recovery`) on that basis rather than on an alert.

So the gap was not theoretical. It had already swallowed one real failure, and
the only reason it did not turn into data loss is that a different tool
happened to complain about the same thing for an unrelated reason.

## Root cause
A backup alert scoped by an explicit list of namespaces. Adding a service that
needs backing up requires editing that list, nothing enforces it, and the
failure mode of forgetting is silence, which is indistinguishable from success.

## Fix
`k8s/apps/monitoring/homelab-rules.yaml`, `homelab.backups` group:

- Dropped the `namespace=~"..."` filter from `BackupJobFailed` and
  `BackupJobMissing`. They now match on job name alone, so any namespace that
  starts running a backup job is covered from its first run. `BackupJobMissing`
  already aggregated `by (namespace)`, so it self-scopes correctly.
- Added `BackupJobsAbsent`, a guard, same pattern as `LonghornMetricsAbsent`
  and `PortfolioMetricsAbsent`. Self-scoping rules cannot see a namespace whose
  backups vanish entirely: no Jobs, no series, nothing to compare a timestamp
  against. The guard is the one place the expected set is written down, and its
  failure mode is firing rather than silence.

## Verification
Every expression checked against live data before it was committed, and the
guard checked for the failure that guards usually have, being vacuously empty:

```bash
# new BackupJobFailed / BackupJobMissing → empty (nothing failing, nothing stale)
# and the age query now returns four namespaces, not three:
#   gitea 77131s  immich 74795s  nextcloud 78662s  paperless 73575s   (all < 26h)

# the guard, as written → empty (all four namespaces have backup Job series)
# the guard + one bogus namespace appended → exactly one series:
#   {"namespace":"doesnotexist"} => 1
```

That last check is the one that matters. It proves the guard can fire and that
`absent()` keeps the `namespace` label, so `{{ $labels.namespace }}` renders.
The first cut of `LonghornVolumeDegraded` compared `== 2` against a metric that
never held 2, and looked exactly as healthy as this did.

```bash
kubectl apply --dry-run=server -f k8s/apps/monitoring/homelab-rules.yaml
# vmrule.operator.victoriametrics.com/homelab-rules configured (server dry run)
```

## Prevention
The self-scoping rules mean the specific mistake, ship a service, forget the
alert, cannot recur: coverage now starts with the first backup run.

What still needs a human is `BackupJobsAbsent`'s namespace list, when a service
*stops* being backed up or is renamed. Keep it in step with the `for ns in ...`
loops in `docs/runbooks/backup-verification.md`; those two lists should always
agree, and either one disagreeing with `kubectl get cronjob -A` is the smell.

Accepted tradeoff: a one-off Job matching `.*backup.*` left lying around in a
namespace with no ongoing CronJob will trip `BackupJobMissing` 26h later. The
remedy is deleting the leftover Job, which you would do anyway. Manual recovery
runs in namespaces that already have a CronJob are fine, they just move the
timestamp forward.

## Related
- Lessons: `docs/lessons/storage/longhorn-autosalvage-blocked-diskpressure.md` (the 2026-07-26 event whose paperless failure went unalerted)
- Lessons: `docs/lessons/backup/restic-retention-never-pruned.md` (found via the gitea/immich alerts that *did* fire from that same event)
- Lessons: `docs/lessons/k8s/k3s-control-plane-false-positives.md`, `docs/lessons/k8s/alertmanager-null-route-typo.md` (the other direction: alerts that fire and shouldn't)
- ADR: `docs/adr/015-paperless-ngx.md`, `docs/adr/004-restic-b2-bckup.md`
- Runbook: `docs/runbooks/backup-verification.md`
