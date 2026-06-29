# Incident: nextcloud-cron jobs failing with RWO Multi-Attach (KubeJobFailed)

## Date
2026-06-29

## Time lost
~20m (mostly confirming the alternating pass/fail pattern was node placement)

## Status
Resolved.

## Context
- **System / component:** `nextcloud` namespace, k3s cluster — the `nextcloud-cron`
  CronJob (runs `cron.php` every 5 minutes).
- **Scope:** Background jobs only. The main Nextcloud pod, DB, and web UI were
  unaffected the whole time.
- **State before:** Steady state. Alertmanager fired `KubeJobFailed` for
  `nextcloud-cron-29711565`, runbook says "remove the failed job to clear".

## Symptoms
- A stream of `KubeJobFailed` alerts, a new one roughly every 5–10 minutes.
- Cron runs alternated: some `Complete`, some `Failed`.
- `failedJobsHistoryLimit: 3` kept up to three failed jobs around, so the alert
  never self-cleared.
- The smoking gun was in the namespace events, not the pod logs (the failing
  pods never started a container):
  ```text
  Warning  FailedAttachVolume  Multi-Attach error for volume "pvc-04f933a1-..."
           Volume is already used by pod(s) nextcloud-844bd8557d-plc7h
  Warning  DeadlineExceeded    Job was active longer than specified deadline
  ```
- Frequency: intermittent, ~half of all runs.

## Investigation
- `kubectl logs` on the failed job returned nothing — the container never ran,
  so the failure was pre-start (scheduling/volume), not application logic.
- Pulled `kubectl get events --field-selector type=Warning` and saw a clean
  alternating pattern of `FailedAttachVolume` → `DeadlineExceeded` going back
  ~50 minutes.
- Correlated node placement against outcome:
  - main pod `nextcloud-844bd8557d-plc7h` → **k3s-worker1**
  - cron `29711580` (Complete) → **k3s-worker1** (same node)
  - cron `29711590` (Failed) → **k3s-control** (different node)
- `nextcloud-data` PVC confirmed `ReadWriteOnce` on Longhorn.

## Root cause
`nextcloud-data` is an **RWO** Longhorn volume — it can only attach to one node
at a time, and the main Nextcloud pod holds it on whichever node it runs
(k3s-worker1). The `nextcloud-cron` CronJob had **no affinity**, so the scheduler
placed each run on any node. Runs landing on k3s-worker1 attached the volume and
completed; runs landing on any other node hit a Multi-Attach error, hung until
`activeDeadlineSeconds: 280`, and were killed as `DeadlineExceeded` → `Failed`.

Note: HOMELAB.md already described the cron as "podAffinity pins to worker" and
the Longhorn RWO section already stated CronJobs sharing an RWO PVC *must* use
podAffinity — the manifest had simply drifted from the documented intent. The
guard rail was written down but never implemented in `cronjob.yaml`.

## Fix
Added a required `podAffinity` to the cron jobTemplate so it always co-schedules
onto the node already running the main pod (and therefore the attached volume).

```yaml
# k8s/apps/nextcloud/cronjob.yaml — jobTemplate.spec.template.spec
affinity:
  podAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      - labelSelector:
          matchLabels:
            app: nextcloud
        topologyKey: kubernetes.io/hostname
```

Deployed via ArgoCD (app `nextcloud`, auto-sync prune+selfHeal, source
`k8s/apps/nextcloud`) on push to `main`. Lingering failed jobs were then deleted
to clear the active alert — they don't age out on their own unless new failures
push them past `failedJobsHistoryLimit`:

```bash
kubectl delete job -n nextcloud \
  nextcloud-cron-29711570 nextcloud-cron-29711575 nextcloud-cron-29711585
```

## Verification
```bash
# every cron pod now lands on the same node as the main pod
kubectl get pods -n nextcloud -o wide | grep nextcloud-cron
# subsequent runs Complete, no new Failed jobs, no FailedAttachVolume events
kubectl get jobs -n nextcloud
kubectl get events -n nextcloud --field-selector type=Warning
```

## Prevention
- The rule was already in HOMELAB.md ("Longhorn RWO: CronJobs sharing a RWO PVC
  must use podAffinity"); the gap was implementation. **Any CronJob/Job mounting
  an app's RWO PVC needs podAffinity to the app pod, full stop.**
- Audited the other RWO-mounting CronJobs while here — all three backup jobs
  already carry the affinity and were never affected: `nextcloud-backup`
  (`app: nextcloud`), `gitea-backup` (`app: gitea`), `immich-backup`
  (`app: immich-server`). The pattern was established for the backup jobs; the
  small every-5-min `nextcloud-cron` was simply the one that got overlooked.
- When a Job fails pre-container-start, check namespace `Warning` events for
  `FailedAttachVolume` before digging into pod logs — the logs will be empty.

## Related
- ADR: docs/adr/002 (Nextcloud on Longhorn PVC, "no node-pinning" — that
  assumption is what this bug exposes for the cron/backup workloads)
- Other lessons: docs/lessons/k8s/argocd-selfheal-backup-race.md
- HOMELAB.md: "Longhorn RWO" notes; Nextcloud "Background jobs" line
