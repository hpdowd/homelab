# Incident: Grafana CrashLoopBackOff — corrupted SQLite on a reused PVC

## Date
2026-06-05 / 2026-06-06

## Time lost
~Several hours across multiple reinstall attempts.

## Status
Resolved.

## Context
- **System / component:** `vm-grafana` (Grafana bundled in the
  `victoria-metrics-k8s-stack` Helm chart), namespace `monitoring`, deployed via
  ArgoCD. Grafana state on a `local-path` PVC pinned to the worker.
- **Scope:** Monitoring stack only — blocked the whole ArgoCD app from going
  Healthy (degraded Grafana held the Application in Progressing/Degraded).
- **State before:** First-time deploy of the monitoring stack, followed by several
  teardown/reinstall cycles while debugging.

## Symptoms
- `vm-grafana` pod(s) stuck in `CrashLoopBackOff`; readiness probe to
  `/api/health` refused connection because the process exited during startup.
- Two Grafana ReplicaSets (rev:1 and rev:2) each holding a pod — a stuck rollout,
  not intentional.
- Error evolved across attempts:
  ```text
  # first:
  Datasource provisioning error: no such column: provisioned
  # later:
  Failed to get current data key ... NOT NULL constraint failed: data_keys.id (1299)
  ```

## Investigation
- **Hypothesis 1 — Grafana version regression.** Initially blamed a Grafana point
  release. **Wrong** — never verified, and the error is about DB *state*, not code.
- **Hypothesis 2 — two pods fighting one RWO volume.** Partly true: the stuck
  rollout left two ReplicaSets both mounting the same RWO `local-path` PVC, which
  a single SQLite file cannot tolerate. But not the root cause.
- **Hypothesis 3 — corrupted DB on a surviving PVC.** Confirmed: the Grafana PVC
  persisted across namespace deletions / reinstalls and carried a half-initialised
  SQLite schema. New Grafana could not reconcile it (`data_keys` table — Grafana's
  envelope-encryption store — was in a bad state, so provisioning the datasource
  failed on the encrypt step).

## Root cause
A reused `local-path` PVC carried a corrupted/half-migrated Grafana SQLite DB
across reinstalls. Every fresh deploy inherited the broken `data_keys` table and
failed datasource provisioning. The two-ReplicaSet rollout compounded it by having
two processes contend for the same RWO volume.

## Fix
```bash
# Stop ArgoCD recreating things mid-fix
argocd app set victoria-metrics --sync-policy none
# Scale to 0 so BOTH replicasets release the PVC
kubectl scale deployment vm-grafana -n monitoring --replicas=0
# (wait for both grafana pods to terminate)
# Delete the corrupted PVC so Grafana reinitialises a clean DB
kubectl delete pvc vm-grafana -n monitoring
# Re-enable — fresh PVC, clean schema, single clean rollout
argocd app set victoria-metrics --sync-policy automated --auto-prune --self-heal
argocd app sync victoria-metrics
```

## Verification
```bash
kubectl get pods -n monitoring        # vm-grafana 3/3 Running, 0 restarts
# Grafana UI → Connections → Data sources → VictoriaMetrics → Test → green
```

## Prevention
- **Strongly consider `grafana.persistence.enabled: false`.** Dashboards are
  GitOps ConfigMaps (sidecar auto-loads) and the datasource is chart-provisioned,
  so the PVC only holds the admin password + user prefs. Running Grafana on
  emptyDir makes every restart clean and this corruption class impossible.
  If keeping persistence, set the admin password from a SealedSecret so a future
  PVC wipe is a non-event.
- **Pin chart versions to a verified number.** Confirm with
  `helm search repo vm/victoria-metrics-k8s-stack` — do not trust a version from
  memory/assumption (a guessed version sent us down a wrong path early on).
- **`local-path` reclaim is `Delete`, but PVCs can linger** through messy
  teardowns. When reinstalling stateful apps after a failed deploy, explicitly
  delete the PVC rather than assuming namespace deletion took it.

## Related
- Namespace got stuck `Terminating` during teardown due to vm-operator finalizers
  (`apps.victoriametrics.com/finalizer`) — see runbook: force-clear a stuck
  namespace (patch CR finalizers, then the namespace `finalize` subresource).
- ADR 005 (VictoriaMetrics monitoring) — TSDB/Grafana storage decisions.
