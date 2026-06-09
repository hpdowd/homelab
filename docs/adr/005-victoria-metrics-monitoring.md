# ADR 005 — Monitoring: VictoriaMetrics single-node, off Longhorn, pinned to the worker

**Status:** Accepted
**Date:** 2026-06
**Superseded By:** —

## What problem this solves

I want real visibility into the cluster — metrics, dashboards, alerts —
before I add anything else heavy (Immich, mostly). Without it I'm guessing
at "is this node out of RAM?" and "did the backup run?" and that's not OK
for things I depend on.

The constraint that shapes every choice below is RAM. The Proxmox host has
~24GB. Once the VMs reserve theirs (worker 14GB + control 3GB), there's
maybe 6–7GB left for the host itself, ZFS ARC, and the LXCs that didn't
move to the cluster. There's not much slack for "the monitoring stack". Anything
that wants 1.5GB is out.

The other constraint is disk. The 500GB Longhorn vdb is finite, and writes
to it cost extra because Longhorn replicates them. A TSDB doing 10s scrapes
hammers that, and the metrics it's writing are regenerable — losing them is
fine.

## What I picked

1. **VictoriaMetrics single-node (`vmsingle`), not the cluster variant.** The
   cluster mode splits into vmstorage / vmselect / vminsert, which is great
   if you have multiple storage nodes. I have one worker. Single-node is
   ~60MB resident and ships in the same `victoria-metrics-k8s-stack` Helm
   chart, so it's also one fewer decision later. I picked it over
   `kube-prometheus-stack` because the latter wants ~60–70% more RAM, and
   the budget doesn't have it. Same kind of trade I made on Authelia vs
   Authentik.

2. **The TSDB lives on `local-path`, not Longhorn, pinned to the worker.**
   The data is throwaway in the disaster sense (I'd rather have a fresh
   30-day window than wait for a Longhorn rebuild), and it spares the vdb
   from being chewed on by ~50k samples/min of scrape writes. Retention is
   30 days, which is plenty for "what changed recently".

3. **The heavy components are all pinned to the worker.** vmsingle, vmalert,
   alertmanager, grafana, kube-state-metrics — every one of them lives on
   k3s-worker1. The control node is tight on RAM and I don't want a
   monitoring spike to fight the API server for memory. The one exception
   is node-exporter, which is a DaemonSet and runs on both nodes on purpose:
   I want host metrics from control too.

4. **Alerts go to email for now, ntfy probably later.** Email needs nothing
   running on my side — Proton handles SMTP. ntfy is nicer for phone
   notifications but means another service to run. Alertmanager's `receiver`
   block is a one-line swap when I get round to it. The SMTP password is in
   a SealedSecret *and* in my password manager, same as
   `RESTIC_PASSWORD`.

5. **Dashboards and alert rules are in git, not the Grafana UI.** The custom
   "Capacity / RAM headroom" board ships as a labelled ConfigMap; Grafana's
   sidecar picks it up automatically. The homelab alert rules sit in
   `homelab-rules.yaml` and cover the things that have actually bitten me
   or that I'd want to know about quietly: memory and swap pressure,
   OOMKills, CrashLoopBackOff, disk filling up, Longhorn going degraded,
   and — biggest — backups failing or going silently missing. A silently
   broken backup is the failure mode I lose sleep over.

## Consequences I should remember

- The whole stack costs ~300–350MB inside the worker's already-reserved 14GB.
  It eats worker slack, not host RAM. Cheap.
- The capacity dashboard is the thing I look at before saying yes to Immich.
- **ZFS pool health on the host is not visible from inside the cluster.**
  node-exporter inside the worker sees the worker's disks, not the
  underlying ZFS tank. Follow-up: stand up node-exporter (or pve-exporter)
  on the Proxmox host and scrape it via the EndpointSlice pattern I already
  use for AMP and Proxmox.
- I did *not* take RAM from the worker to grow the control node. Control's
  usage is stable and small; the worker hosts the real workloads and the
  eventual Immich. If control ever struggles, that comes from host slack,
  not from robbing the worker.

## Addendum — 2026-06-08: Grafana datasource provisioning

The chart's default Grafana integration installs the `victoriametrics-datasource` plugin and
provisions a datasource of that plugin type. On this cluster the plugin coordinate 404s on the
Grafana registry, and because `GF_PLUGINS_PREINSTALL_SYNC` treats a failed preinstall as fatal,
Grafana would not start.

**Decision:** drop the VM datasource plugin entirely and provision a plain `type: prometheus`
datasource pointed at vmsingle. VictoriaMetrics implements the Prometheus query API, so dashboards,
Explore, and alerting all work unchanged; the only thing lost is MetricsQL editor autocomplete,
which is not worth a fatal startup dependency. The chart's datasources **sidecar** is disabled to
avoid a second provisioned default colliding with the inline one. See
`docs/lessons/k8s/grafana-monitoring-sync-cascade.md`.
