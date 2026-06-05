# ADR 005 — Monitoring: VictoriaMetrics single-node, TSDB off Longhorn, worker-pinned

## Status
Accepted — 2026-06

## Context
The homelab needed thorough monitoring (metrics, dashboards, alerting) before
adding further RAM-hungry workloads (Immich) to a host already touching swap.
Constraints:
- Host-level RAM is the ceiling: control VM 3GB + worker VM 14GB = 17GB fixed
  floor, leaving ~6–7GB for the Proxmox host + ZFS ARC + remaining LXCs.
- Inside the cluster the worker has slack (~25% of 14GB used); the control node
  is tighter (~70% of 3GB).
- The 500GB Longhorn vdb is scarce and replication adds write amplification.

## Decision
1. **VictoriaMetrics single-node (`vmsingle`), not the cluster variant.** The
   vmstorage/vmselect/vminsert split is for horizontal scale we don't have on one
   worker. Single-node is ~60MB and bundles cleanly via `victoria-metrics-k8s-stack`.
   Chosen over kube-prometheus-stack for ~60–70% lower RAM (consistent with the
   standing "lightweight at this hardware scale" principle; cf. Authelia over
   Authentik).
2. **TSDB on local-path, pinned to the worker — deliberately NOT Longhorn.**
   Monitoring data is regenerable; losing it on a node rebuild is acceptable.
   Keeping it off Longhorn spares the vdb and avoids replication overhead for
   low-value data. Retention 30d.
3. **Heavy components pinned to the worker** (vmsingle, vmalert, alertmanager,
   grafana, kube-state-metrics) so they never compete with the control plane.
   node-exporter is a DaemonSet and runs on BOTH nodes — host metrics from
   control are wanted.
4. **Alerting to email now; ntfy as a fast-follow.** Email needs no extra running
   service (just an SMTP relay). Alertmanager receiver is a one-line swap to ntfy
   later. SMTP password sealed (SealedSecret) and also stored in the password
   manager, same discipline as RESTIC_PASSWORD.
5. **Dashboards and alert rules as code.** Custom capacity dashboard ships as a
   labelled ConfigMap (sidecar auto-load); community dashboards by grafana.com ID.
   Homelab-specific PrometheusRule covers the known failure modes: memory/swap
   pressure, OOMKilled, CrashLoop, disk filling, Longhorn degraded, and — most
   importantly — **backup CronJob failed/missing** (the backups were just built;
   a silent backup failure is the worst case).

## Consequences
- Monitoring adds ~300–350MB inside the worker VM's existing reservation — it
  consumes worker slack, not new host RAM. Cheap.
- The capacity dashboard becomes the data source for the Immich go/no-go decision.
- ZFS pool health on the Proxmox HOST is not visible to in-cluster node-exporter
  (it sees the worker VM's disks). Follow-up: run node-exporter or PVE-exporter on
  the Proxmox host and scrape it as an external target (same EndpointSlice pattern
  as AMP/Proxmox).
- Did NOT reallocate RAM from worker to control: control's usage is stable and
  won't grow; the worker hosts real workloads + future Immich. If control ever
  struggles, bump it from host slack rather than robbing the worker.
