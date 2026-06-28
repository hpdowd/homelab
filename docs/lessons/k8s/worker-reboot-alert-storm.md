# Incident: Worker reboot fires a stale crashloop alert storm

## Date
2026-06-27

## Time lost
~1h diagnosis. No actual outage.

## Status
Resolved. The crashloop storm is benign; the delayed second act (control-node `longhorn-manager` memory) needed a manager restart.

## Context
- **System / component:** k3s-worker1 (VM 301) and cluster-wide alerting (`homelab-rules` VMRule).
- **Scope:** every workload pod on the worker, plus the monitoring stack itself.
- **State before:** a deliberate worker RAM shrink 14→12GiB via graceful `qm shutdown`/`qm start` (handing ~2GiB back to the host for an AMP game server).

## Symptoms
- A batch of `PodCrashLooping` email alerts arrived ~10-20 min *after* the planned reboot, all at once: kube-system (local-path-provisioner), nextcloud (redis), monitoring (6), metallb-system (3), longhorn-system (11).
- Every pod was already `Running`/healthy by the time the alerts landed.
- All cleared on their own except one unrelated new alert, `PortfolioMetricsAbsent` (separate root cause, see gotchas / portfolio repo).
- The smoking-gun events were storage, not memory:
  ```text
  driver.longhorn.io not found in the list of registered CSI drivers
  Engine of volume ... dead unexpectedly ... faulted   (DetachedUnexpectedly)
  Replica ... will be automatically salvaged           (AutoSalvaged)
  ```

## Investigation
- **Hyp 1: the 12GiB shrink starved the node, OOM cascade.** Ruled out: no `OOMKilled` in any container `lastState`, `MemoryPressure: False`, worker at 59%, and crucially **no `PodOOMKilled` alert** fired (the critical rule that ANDs restart-increase with `last_terminated_reason="OOMKilled"`). The absence of that alert is itself the proof it wasn't memory.
- **Hyp 2: pods still crashing.** Ruled out: every alerted pod `Running`, last-restart timestamps ~11m old and stable (a live crashloop keeps resetting to seconds-ago).
- **Phantom tell:** `local-path-provisioner` alerted, but its last actual restart was 18 days ago and it runs on the *control* node, which never rebooted. So at least some alerts were counter-gap artifacts, not real restarts.

## Root cause
Two mechanisms stacked:

1. **Real, transient.** On the worker reboot, Longhorn volumes detached uncleanly (`faulted`) and the CSI driver hadn't re-registered yet, so every pod that mounts a PVC crash-restarted for a few minutes until Longhorn `AutoSalvaged` the replicas and reattached. That genuinely pushed `kube_pod_container_status_restarts_total` up by >3, tripping `PodCrashLooping` (`increase(...[15m]) > 3`, `for: 5m`).
2. **The alerter is on the same worker.** vmalert / vmalertmanager / kube-state-metrics all went down during the reboot, so nothing fired or sent live. On recovery, vmalert evaluated against the trailing 15m (which still held the reboot restarts), the `for: 5m` elapsed, and vmalertmanager flushed the whole batch at once, hence the delayed, simultaneous arrival for an already-healthy cluster. The scrape gap also produced phantom fires (local-path-provisioner) via `increase()` extrapolation across the gap.

`PodCrashLooping` is a restart-*rate* threshold: it cannot tell a one-off reboot from a real crashloop, and it lags reality by `[15m] + for:5m`, up to ~20 min.

## Fix
None. Benign. The alerts self-resolved as the restart counts aged out of the 15m window.

## Verification
```bash
# nothing actually unready (header-only output = all good):
kubectl get pods -A | awk 'NR==1 || ($4!="Completed" && split($3,a,"/") && a[1]!=a[2])'
# not a memory problem:
kubectl describe node k3s-worker1 | grep -A6 Conditions          # MemoryPressure False
kubectl top nodes
# storage recovered:
kubectl get volumes.longhorn.io -n longhorn-system \
  -o custom-columns=NAME:.metadata.name,STATE:.status.state,ROBUSTNESS:.status.robustness
```

## Prevention
Triage from the alert *set* first, before touching kubectl. The discriminator:

| Also received… | Meaning |
|---|---|
| `PodOOMKilled` (critical) | memory starvation, the real emergency |
| `NodeMemoryLowWorker` | worker genuinely out of RAM |
| `LonghornVolumeDegraded` persisting (>5m) | storage did not self-heal |
| **only `PodCrashLooping` (warning), clustered right after a reboot** | **benign reboot fallout, self-resolves in ~20 min** |

So: `PodCrashLooping` *without* `PodOOMKilled`/`NodeMemoryLowWorker`, pods now showing minutes-old-and-stable restart ages, equals reboot noise. Wait it out.

Accepted risk: the monitoring stack lives on the only worker, so it is blind to its own node's reboot and re-fires a batch on every cycle. If it becomes annoying, options are an inhibit rule for the post-restart window, or moving Alertmanager off the worker.

## Delayed second act: control-node longhorn-manager bloat (2026-06-28)

~7h after the reboot, `NodeMemoryLowControl` fired (control `MemAvailable`
< 0.75GiB). It looked unrelated, control was never rebooted, and two
hypotheses were wrong before the real one:

- **Not the apiserver** (suspected my own heavy `kubectl` querying): its RSS
  just oscillates 1.6-1.8GiB with no step.
- **Not gradual drift:** control sat flat at ~0.9GiB available for a week.

The actual cause: the control-node `longhorn-manager` (the controller
leader) sat flat at ~490MiB for a week, then **stepped +150MiB to ~640MiB
between 1 and 5 hours after the reboot** and held it. The reboot had
faulted/AutoSalvaged all 8 volumes; the manager then ran the rebuild/resync
plus the recurring snapshot/trim/backup jobs on every reattached volume
(logs for the window: 121 salvage / 28 snapshot / 14 trim / 14 backup),
growing its Go heap. On a 4GiB control node with ~0.9GiB headroom that
crossed the 0.75GiB floor, hours after the crashloop storm had already
cleared, which is why it didn't look reboot-related.

Diagnosis tell: a clean +150MiB step in **one pod** hours after the reboot,
no new pod scheduled on control, no apiserver step. A `MemAvailable` drop
means *anonymous* (non-reclaimable) memory grew, so diff per-pod
`container_memory_working_set_bytes` and per-process
`process_resident_memory_bytes` over the window to find the one that stepped.

Fix, reclaim the held heap by bouncing the manager (safe, no replicas on
control, volumes stay attached):

```bash
kubectl delete pod -n longhorn-system -l app=longhorn-manager \
  --field-selector spec.nodeName=k3s-control
# control MemAvailable 0.74 -> 0.95 GiB; all 8 volumes stayed healthy
```

Prevention: this recurs on **every** worker reboot. Durable fix is control
4->5GiB (affordable from the 2026-06-27 worker-shrink headroom; +512MiB
covers the spike but not the multi-day apiserver/kine drift, so 1GiB is the
fix-once size). The control-node manager is ~490MiB of dead weight on a node
with zero replicas, so excluding control from Longhorn is the alternative.

## Related
- Gotchas: `docs/reference/gotchas.md` (Monitoring).
- Similar false-positive-alert theme: `docs/lessons/k8s/k3s-control-plane-false-positives.md`.
- Longhorn single-replica reattach behaviour: `docs/reference/gotchas.md` (Longhorn), ADR 005.
- Capacity context for the shrink: `docs/reference/capacity-headroom.md`.
