# Incident: ArgoCD selfHeal raced the Gitea backup's scale-to-0, every backup ran hot

## Date
2026-06-12

## Time lost
~1h. No outage, found while verifying the backup pipeline. Nothing ever
looked broken, which is exactly why it lasted as long as it did.

## Status
Resolved

## Context
- **System / component:** `gitea` namespace, backup CronJob + ArgoCD app
- **Scope:** every nightly Gitea backup since the CronJob was deployed
- **State before:** backups green every night, snapshots restorable,
  SQLite `integrity_check` passing on a test restore. Everything *looked*
  perfect.

## Symptoms
None. The backup is supposed to scale Gitea to 0, copy the idle SQLite
file, and scale back to 1. The job logged "Gitea scaled down" and went
green every night. It only showed up when watching a manual run live:

- The Gitea pod's `creationTimestamp` landed *inside* the backup window
  (recreated seconds after the scale-down).
- `managedFields` on the Deployment showed `argocd-controller` as the
  owner of `spec.replicas` with a timestamp matching the same second.

## Investigation
- Ran `kubectl create job --from=cronjob/gitea-backup` and polled
  `spec.replicas` every 10s → never saw 0, yet the job logged a
  successful scale-down → something restored it between polls.
- `--show-managed-fields` → `argocd-controller` wrote `replicas` at the
  exact second the pod came back → selfHeal, not the job's trap.
- Dead end: the first fix attempt looked like it failed, re-ran the
  test seconds after pushing and the race recurred. Turned out the gitea
  Application object is itself synced by root-app (~3 min poll), so the
  new `ignoreDifferences` wasn't live in the cluster yet. Check the
  Application spec in-cluster before re-testing, not just git.

## Root cause
`selfHeal: true` reverts any live drift from git within seconds. The
backup's scale-to-0 *is* drift (`replicas: 1` in git), so ArgoCD scaled
Gitea back up almost immediately, and the backup copied the SQLite file
from a running instance every night. The `trap`/scale-1 logic in the job
masked nothing, the job still exited 0.

It never produced a corrupt snapshot (3:30am Gitea is idle, WAL
checkpointed), but the consistency guarantee the scale-down exists for
wasn't actually there.

## Fix
Tell ArgoCD that nothing in git owns `spec.replicas` on this Deployment:

```yaml
# k8s/apps/gitea.yaml (Application)
spec:
  ignoreDifferences:
    - group: apps
      kind: Deployment
      name: gitea
      namespace: gitea
      jsonPointers:
        - /spec/replicas
  syncPolicy:
    syncOptions:
      - RespectIgnoreDifferences=true
```

`ignoreDifferences` alone only affects diffing; `RespectIgnoreDifferences`
makes syncs leave the field alone too.

## Verification
Re-ran the manual backup job after confirming the Application spec was
live in-cluster:

- 8 consecutive 5s polls saw `spec.replicas=0` (≈40s genuinely down)
- the new Gitea pod's `creationTimestamp` postdates the job's own
  "Scaling Gitea back up" step
- app stayed `Synced` throughout (no OutOfSync flapping nightly)

## Prevention
- Any future job that scales a GitOps-managed workload needs the same
  `ignoreDifferences` treatment, added to gotchas.md.
- `managedFields` (`--show-managed-fields`) is the fast way to answer
  "who keeps changing this field", faster than log spelunking.

## Related
- ADR 004 (why Gitea's backup scales to 0 at all)
- docs/lessons/k8s/argocd-comparisonerror-silent-values.md (same theme:
  ArgoCD failures are silent by default)
