# Incident: an isolated CronJob failure alerted for 25 hours because nothing ever deleted it

## Date
2026-09-02 → 2026-09-03 (recurrence 2026-09-19)

## Time lost
~1h, all of it after the fact — the alert itself was benign, the cost was
re-triaging the same email every 6h and then working out why it would not stop.

## Status
Resolved. Recurred 2026-09-19 for a different reason — see the Recurrence
section; the manifest fix was correct but did not cover pre-existing Jobs.

## Context
- **System / component:** `nextcloud-cron` CronJob, `nextcloud` namespace
  (`*/5 * * * *`, `activeDeadlineSeconds: 280`, `failedJobsHistoryLimit: 3`).
- **Scope:** alerting only. Nextcloud's background jobs were running normally
  the whole time — the *next* run, five minutes later, succeeded.
- **State before:** both k3s nodes rebooted at `2026-09-02T15:40:35Z`.

## Symptoms
- `KubeJobFailed` firing continuously from ~15:45 on 2026-09-02, re-notifying
  every 6h into email, for a single `nextcloud-cron-*` Job.
- The Job stayed in the namespace as `Failed` indefinitely:

  ```text
  nextcloud-cron-297xxxxx   0/1   DeadlineExceeded
  ```

- Every subsequent run completed in ~4s. Nothing else was wrong.
- Frequency: one-off in origin, permanent in effect.

## Investigation
- **Hyp 1: Nextcloud's cron is actually broken.** Ruled out — later Jobs all
  `Complete` in seconds, `occ status` healthy, no data impact.
- **Hyp 2: the RWO multi-attach race again**
  (`nextcloud-cron-multiattach-rwo.md`). Ruled out — the podAffinity fix is in
  place and the run was on the right node. This one hung because it started
  **6 seconds after the node came back**, before postgres and the main
  Nextcloud pod were Ready, so it sat waiting on the DB until
  `activeDeadlineSeconds: 280` killed it.
- **Hyp 3: `failedJobsHistoryLimit: 3` will clean it up.** This is the one that
  matters, and it is wrong in a way that reads as correct. The limit is not a
  TTL. The CronJob controller trims failed Jobs **only when it creates a new
  failed Job** and the count exceeds the limit. An isolated failure with no
  further failures behind it is never trimmed, so it is retained forever, and
  `KubeJobFailed` — which fires on the existence of a failed Job — fires
  forever with it.
- The four earlier `nextcloud-cron` failures (the multi-attach ones) had
  *appeared* to self-clear within minutes. They did, but only because they came
  in bursts and evicted each other. That self-healing behaviour is what made
  the retention rule look like a TTL for months.

## Root cause
`failedJobsHistoryLimit` is a **count-triggered** garbage collector, not a
time-based one. It evicts on the arrival of a newer failure, so exactly one
failed Job — the isolated case — survives indefinitely. `KubeJobFailed` alerts
on the presence of a failed Job, not on a recent failure, so the alert's
lifetime is the Job object's lifetime. The trigger (a node reboot racing the
`*/5` schedule against postgres startup) was a one-off; the 25-hour alert was
the retention semantics.

## Fix
Declarative, in `k8s/apps/nextcloud/cronjob.yaml`:

```yaml
spec:
  jobTemplate:
    spec:
      ttlSecondsAfterFinished: 86400   # self-delete finished Jobs after 24h
```

24h keeps the Job and its pod logs for a full day of investigation — the alert
only fires 15m in — and then lets the alert resolve on its own instead of
waiting for a human with `kubectl delete job`.

**Deliberately not applied to the backup CronJobs.** A failed backup is
high-consequence and rare, and *should* keep shouting until someone actually
looks at it. The asymmetry is the point: TTL is right for a noisy 5-minute
housekeeping job, wrong for the thing that protects the data.

## Verification
```bash
# the stuck Job is gone and the alert cleared
kubectl -n nextcloud get jobs
# later runs complete in seconds
kubectl -n nextcloud get jobs -l app=nextcloud-cron
```

## Prevention
- **`failedJobsHistoryLimit` is not a TTL, and neither is
  `successfulJobsHistoryLimit`.** If an alert keys on the *existence* of a
  failed Job, only `ttlSecondsAfterFinished` bounds how long it can fire.
- **A burst of failures self-clears; a lone failure does not.** That is the
  opposite of the intuition, and it is why this looked like it would resolve
  itself for the first few hours.
- **A CronJob on a short schedule will fire during node startup.** Anything on
  `*/5` will eventually run seconds after a reboot, before its dependencies are
  Ready. Either make the job tolerate it (a `pg_isready` wait-guard, the same
  guard the netpol lesson asks for) or make the resulting failure disposable,
  as here.
- When an alert will not clear after the underlying fault is gone, check
  whether it is asserting on a *state object* rather than an event.

## Recurrence: 2026-09-19 — the TTL fix is not retroactive

Same alert, twice over, from two `nextcloud-cron` Jobs that failed during the
**2026-09-16** control-plane outage and were still firing three days later.

The `ttlSecondsAfterFinished: 86400` fix above works. It just does not apply to
Jobs that already existed when it landed. `ttlSecondsAfterFinished` is copied
from the CronJob's `jobTemplate` into each Job **at creation time**; it is not
read back from the CronJob afterwards. So Jobs created before the field was
added carry no TTL for the rest of their lives:

```
$ kubectl -n nextcloud get jobs -o json | jq '.items[] | {name:.metadata.name, ttl:.spec.ttlSecondsAfterFinished}'
nextcloud-cron-29826310   ttl: null     <-- created pre-fix, never GC'd
nextcloud-cron-29826475   ttl: null     <-- created pre-fix, never GC'd
nextcloud-cron-29829665   ttl: 86400    <-- created post-fix, self-deletes
```

And `failedJobsHistoryLimit: 3` did not save it either, for the reason this
lesson already documents: two failures is under the limit of three, so the
count-triggered GC never fired. Both mechanisms declined for different reasons.

### Why the Jobs failed in the first place

Not a Nextcloud fault. The control-plane VM died uncleanly at
`2026-09-16 18:12:22 BST` — the k3s journal stops mid-line with no shutdown
sequence — and took **2h44m** to come back across five manual `qm` stop/start
attempts and a full PVE host reboot:

```text
18:12:22  k3s-control journal ends mid-stream (unclean stop)
18:27:45  qmstop 300 / 18:29:14 qmstart 300   } manual recovery attempts
18:30:39  qmstop 300 / 18:30:46 qmstart 300   }
19:18:34  stopall  →  19:22:34 startall        (PVE host reboot)
19:56:08  qmstart 300  →  control plane finally up at 19:56:20 UTC
```

The in-flight Job (`29826310`, started 17:10 UTC) was only reaped at 19:56:30 —
**2h46m after its 280s deadline**, because nothing was running to enforce the
deadline. It was marked `DeadlineExceeded` the instant the controller returned.
The next scheduled Job failed at exactly 280s while things settled, and
everything since has completed in ~5s.

This is worth recognising on sight: **a Job whose active time wildly exceeds its
`activeDeadlineSeconds` did not hang for that long — the control plane was
absent.** The failure timestamp marks the recovery, not the fault.

### Fix

```bash
kubectl -n nextcloud delete job nextcloud-cron-29826310 nextcloud-cron-29826475
```

No manifest change. `k8s/apps/nextcloud/cronjob.yaml` is already correct, and
every Job created since carries the TTL.

### Verification

```bash
# metric drops first, alert follows within an eval cycle
curl -s 'localhost:8428/prometheus/api/v1/query' \
  --data-urlencode 'query=kube_job_failed{namespace="nextcloud"}>0'   # series: 0
curl -s localhost:8080/api/v1/alerts | jq '[.data.alerts[]|select(.state=="firing").name]'
# ["KubeMemoryOvercommit","KubeCPUOvercommit","Watchdog"]  — both KubeJobFailed gone
```

### Prevention

- **Adding `ttlSecondsAfterFinished` does not clean up the backlog.** When you
  add a TTL to fix a retention bug, sweep the existing objects in the same
  change — the fix only covers objects created after it.
- **Check `.spec.ttlSecondsAfterFinished` on the Job, not the CronJob.** The
  CronJob showing the right value tells you nothing about Jobs already on the
  cluster.
- The two `Kube*Overcommit` warnings firing alongside this are expected on a
  2-node cluster and are already null-routed in
  `k8s/infrastructure/victoria-metrics.yaml` — they are visible in vmalert by
  design and are not part of this incident.

## Related
- Other lessons: `docs/lessons/k8s/nextcloud-cron-multiattach-rwo.md` (the
  earlier, genuinely broken failures on this same CronJob — the ones that
  self-cleared), `docs/lessons/k8s/netpol-fresh-pod-race.md` (short-lived Jobs
  losing a startup race), `docs/lessons/k8s/worker-reboot-alert-storm.md`
  (the other way a reboot turns into alert noise)
- Gotcha: `docs/reference/gotchas.md`, Monitoring section
