# ADR 020: Nothing runs on the control node

**Status:** Accepted
**Date:** 2026-10-09

## Problem

- The kubelet's graceful shutdown (enabled 2026-10-08) terminates the
  worker's pods when it shuts down. Their replacements are scheduled while
  control is the only Ready node, and they stay there after the worker
  returns.
- The scheduler also favours control for any unpinned pod: its pods request
  9% of its memory, against 49% on the worker.
- The 2026-10-08 test reboot of the worker moved about 20 pods to control.
  Its MemAvailable fell from about 1.4GiB to about 0.5GiB, and
  `NodeMemoryLowControl` fired 12 times between 02:02 and 06:48 UTC.
- The VictoriaMetrics stack set a top-level `nodeSelector` that the chart
  never reads, so vmagent and the operator were unpinned without anyone
  knowing.

## Decision

Control runs k3s, its packaged add-ons (coredns, metrics-server,
local-path-provisioner) and node-exporter. Everything else runs on the
worker.

- **Every Deployment and StatefulSet is pinned to the worker** with
  `nodeSelector: kubernetes.io/hostname: k3s-worker1`.
- **Control is tainted `node-role.kubernetes.io/control-plane:NoSchedule`.**
  The k3s add-ons and node-exporter tolerate it. A workload that is missing
  its pin goes Pending during a worker outage instead of landing on control.
- **Longhorn runs on the worker only.** Control is removed as a Longhorn
  node; it held no replicas (`allowScheduling=false`). The CSI sidecars drop
  from three replicas each to one.
- **MetalLB's speaker runs on the worker only**, with Traefik.
- **RAM moves with the workloads:** control 5 → 4GiB, worker 12 → 13GiB. The
  host has about 2.7GiB available and nothing else to give.

| | Control | Worker |
|---|---|---|
| RSS moved (peak) | about −1.2GiB | about +1.1GiB (ArgoCD 0.72, gitea 0.22, Traefik 0.19) |
| RAM | 5 → 4GiB | 12 → 13GiB |
| Low MemAvailable, before | 1.05GiB (week to 10-08) | 2.85GiB (week to 10-08) |
| Low MemAvailable, expected | about 1.3GiB | about 2.8GiB |
| Alert floor | 0.75GiB | 2GiB |

Without the RAM change the worker's expected low is about 1.8GiB, under its
floor.

Where each pin is set:

| Workload | Set in |
|---|---|
| vmagent, VM operator, MetalLB, cloudflared, gitea, kiwix, Traefik | `k8s/` manifests, ArgoCD auto-sync |
| ArgoCD | `bootstrap.sh` (`kubectl patch`); ArgoCD is not managed from `k8s/` |
| Sealed Secrets | `sealed-secrets.yaml` values and `bootstrap.sh` |
| Longhorn | `longhorn.yaml`: manager, UI and driver deployer `nodeSelector`, `systemManagedComponentsNodeSelector` |
| Control taint | `ansible/roles/k3s_node` (`node-taint`). k3s applies it only when a node first registers, so the live node was tainted with `kubectl taint` |
| VM RAM | Proxmox (`qm set`) |

## Applied

On 2026-10-09, in one window:

1. Paused ArgoCD auto-sync on root-app and the six apps with Longhorn volumes,
   scaled their Deployments to 0 and suspended `nextcloud-cron` until every
   volume was detached.
2. Patched ArgoCD onto the worker, then synced the longhorn Application for
   the first time. Longhorn applied the node selector from its default-setting
   ConfigMap and moved every component off control. Deleted the `k3s-control`
   Longhorn node, synced the Sealed Secrets Deployment, tainted control.
3. Scaled the CSI sidecars to 1 by hand: the driver deployer skips CSI
   Deployments it has already deployed at the same version.
4. Applied the Ansible k3s config, set the RAM, shut down the worker then
   control, and started control then the worker.
5. Scaled the apps back up, waited for all 12 volumes to be attached and
   healthy, and resumed auto-sync.

Public services were down for about 30 minutes. Fifteen minutes after the
window, control had 2.0GiB available and the worker 5.8GiB.

## Rejected

- **Pins without the taint.** A workload added without a pin would land on
  control at the next worker reboot, as on 2026-10-08.
- **The taint without pins.** Placement would still depend on the scheduler
  for anything that tolerates the taint, and the pins make each workload's
  node visible in its own manifest.
- **ArgoCD's controller and Traefik on control.** Considered earlier the same
  day to spare the worker's memory. The RAM change covers that, and it keeps
  one rule with no exceptions.
- **More RAM for the worker from the host.** The host has about 2.7GiB
  available, and ZFS ARC holds another 2.3GiB.

## Consequences

- A new workload needs `nodeSelector: kubernetes.io/hostname: k3s-worker1`.
  `operations.md` (Pods + Deployments) has a command that lists unpinned
  workloads.
- When the worker is down, nothing but k3s runs. Every app was already in
  that position.
- After an ArgoCD upgrade, re-run the patch step in `bootstrap.sh`. It is
  idempotent.
- Control's alert floor (0.75GiB) stays. Check both nodes' MemAvailable for a
  week after the RAM change.
- Longhorn changes that need every volume detached (node selector,
  tolerations) need the same window: steps 1, 2 and 5 above.
