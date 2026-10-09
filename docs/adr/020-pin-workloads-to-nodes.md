# ADR 020: Pin every workload to a node

**Status:** Accepted
**Date:** 2026-10-09

## Problem

- The control node (5GiB) has no taint. The scheduler favours the node with
  the smaller share of its memory requested: 9% on control, 49% on the
  worker. A pod with no node pin goes to control.
- Control also boots first (Proxmox startup order 2, worker 3). After the
  2026-10-08 power cut the worker came up 23 minutes after control.
- About 20 unpinned pods started on control that night. Its MemAvailable fell
  from about 1.4GiB to about 0.5GiB, and `NodeMemoryLowControl` fired 12
  times between 02:02 and 06:48.
- The VictoriaMetrics stack set a top-level `nodeSelector` that the chart
  never reads, so vmagent and the operator were unpinned without anyone
  knowing.

## Decision

Every Deployment and StatefulSet sets a node. The worker is the default.
These run on control:

| Workload | Reason |
|---|---|
| ArgoCD application controller, server, applicationset controller | The controller's working set reached 1.57GiB in the week before the power cut, and the worker's low that week was 2.85GiB. On the worker they would take it under its 2GiB alert floor. They ran on control before 2026-10-08 |
| Traefik | It has always run there. The proxmox.lan route then has no dependency on the worker |
| DaemonSets (node-exporter, longhorn-manager, longhorn-csi-plugin, metallb-speaker) | One per node by design |

Where each pin is set:

| Workload | Set in | Applied |
|---|---|---|
| vmagent, VM operator, MetalLB controller, cloudflared, gitea, kiwix, traefik | `k8s/` manifests | By ArgoCD auto-sync |
| Sealed Secrets | `sealed-secrets.yaml` values and `bootstrap.sh` | By a manual sync of the Deployment |
| ArgoCD | `bootstrap.sh` (`kubectl patch`) | By running the patch step. ArgoCD is not managed from `k8s/` |
| Longhorn UI and driver deployer | `longhorn.yaml` values | When Longhorn is adopted |
| Longhorn CSI sidecars | `system-managed-components-node-selector` | Not applied. Longhorn accepts the change only with every volume detached |
| coredns, metrics-server, local-path-provisioner | k3s packaged manifests | Not pinned. k3s deploys them from its own manifests. They stay on control |

## Rejected

- **Taint control `NoSchedule`.** Every DaemonSet that must run there would
  need a toleration. Longhorn sets tolerations for its system-managed
  components through its `taint-toleration` setting, which, like its node
  selector, can be changed only with every volume detached.
- **Leave placement to the scheduler.** This is what happened on 2026-10-08.
- **Everything on the worker, ArgoCD included.** See the ArgoCD row above.

## Consequences

- A new workload needs `nodeSelector: kubernetes.io/hostname: k3s-worker1`.
  Without one it runs on control. `operations.md` (Pods + Deployments) has a
  command that lists unpinned workloads.
- When the worker is down, pinned pods stay Pending instead of starting on
  control. This was already true for every app.
- After an ArgoCD upgrade, re-run the patch step in `bootstrap.sh`. It is
  idempotent.
- The twelve CSI sidecar pods (about 360MiB) stay on control until a storage
  maintenance window. Moving them restricts the instance manager and engine
  image to the worker as well.
