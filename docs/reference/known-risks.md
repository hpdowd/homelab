# Known Risks

Standing list of things that have not broken yet but are on a path to breaking, with the
evidence for each and what would stop it. Reviewed 2026-07-26 after the Longhorn
auto-salvage incident.

Ordered by expected damage, not by how likely they are.

---

## Open actions

Carried out of the 2026-07-25 incident review. The cluster is healthy; none of these are
emergencies, but the first one is the difference between the next reboot self-healing and
repeating a 16-hour outage.

| # | Action | Effort | Blocks | Risk |
|---|---|---|---|---|
| 1 | Drop `storageReserved` on `/mnt/longhorn` to 10%, restoring auto-salvage | one command | — | Scheduling calculation only; nothing detaches |
| 2 | `pip install ansible`, then `site.yml --check --diff` and apply | ~30 min | — | Playbook has never been executed |
| 3 | Route `severity: critical` to a channel that interrupts | ~1h | Needs you to pick ntfy/Gotify/Pushover | Low |
| 4 | Remove the hand-added `[Journal]` block from the worker's `journald.conf` | 2 min | Do after #2 | None |
| 5 | Repoint local-path onto `vdb` | window | Needs #2 (sets the k3s flag) + k3s restart | Moderate — k3s restart |
| 6 | Adopt `k8s/infrastructure/longhorn.yaml` | window | Volumes must be healthy | **Highest here.** Never mid-incident |
| 7 | Decide on worker memory limits at 191% of allocatable | judgement | — | Alert is currently ambient noise |
| 8 | Add a Longhorn `trim` recurring job | ~15 min | — | Low |

Item 1 is the only one where delay carries ongoing exposure. Items 5 and 6 want the same
maintenance window. Item 6 is the one to be slowest about: it is the highest-value
structural fix and the easiest to do damage with.

### Already done (2026-07-25 / 26)

All 11 volumes salvaged and verified (clean mounts, no journal replay, clean postgres WAL
redo, backups re-run successfully). `LonghornDiskUnschedulable` and
`LonghornProvisioningHeadroomLow` alerts committed and live. Worker OS disk 84% → 82%,
journald capped. `ansible/` created. Incident written up in
`docs/lessons/storage/longhorn-autosalvage-blocked-diskpressure.md`.

---

## 1. Longhorn auto-salvage is disabled by disk over-provisioning

**Severity: high. Recurs on the next reboot.**

The worker's data disk sits at `Schedulable: False` / `DiskPressure`, and Longhorn's
auto-salvage skips replicas on an unschedulable disk. Any event that faults the volumes
now needs manual recovery instead of self-healing.

```text
ScheduledTotal   351.0 GiB   (sum of volume spec sizes)
ProvisionedLimit 343.8 GiB   (100% of 491.1 GiB max − 147.3 GiB reserved)
```

Over by ~7.2 GiB. Two compounding causes: `storage-reserved-percentage-for-default-disk=30`
applied 147 GiB of reservation to a *dedicated* data disk that needs none, and Longhorn
schedules on provisioned size, so `immich-library` counts 200 GiB while holding 44 GiB.

**Prevention:**

- **Detection is now in place** (`k8s/apps/monitoring/homelab-rules.yaml`, auto-synced):
  `LonghornDiskUnschedulable` fires critical on
  `longhorn_disk_status{condition="schedulable"} == 0`, and
  `LonghornProvisioningHeadroomLow` warns at 90% of the provisioning limit so the next
  occurrence is caught *before* it disables salvage. Both verified against live series.
  Expressed as a ratio rather than absolute bytes, because an absolute threshold
  false-positives on the control node.
- **The live fix is still outstanding and imperative.** Drop `storageReserved` on
  `/mnt/longhorn` to ~10%, giving a 474 GiB limit against 351 GiB scheduled. Commands and
  the setting-vs-node-object distinction are in `docs/runbooks/cluster-rebuild.md` §3.
  Right-sizing `immich-library` addresses the other half.
- **Durably fixed for a rebuild** via `k8s/infrastructure/longhorn.yaml`
  (`storageReservedPercentageForDefaultDisk: 10`), once that Application is adopted. See
  item 3b.

Full detail: `docs/lessons/storage/longhorn-autosalvage-blocked-diskpressure.md`

---

## 2. Critical alerts fire into email and nothing escalates

**Severity: high. Already cost 16 hours.**

Detection is fine. `LonghornVolumeDegraded` fired correctly and on time during the
2026-07-25 outage, confirmed against stored `ALERTS` series. Eleven volumes then sat
faulted overnight because a critical alert at 19:34 on a Saturday reaches an inbox nobody
is reading.

Every incident so far has been found by looking, not by being told.

**Prevention:** route `severity: critical` to something that interrupts (ntfy, Gotify,
Pushover) and leave `warning` on email. This is a routing change in Alertmanager, not a
new rule.

---

## 3. Worker OS disk cannot absorb its own local-path claims

**Severity: high. Slow-moving, no natural stopping point.**

`/dev/vda2` is 41 GiB and sat at 84% before this review, 82% after cleanup. The space is
not garbage:

| Consumer | Size | Reclaimable? |
|---|---|---|
| containerd images | 24 GiB | No. 49 of 54 images are in use by running containers; 642 snapshot dirs against 643 containerd records, so nothing is orphaned |
| local-path PVs | 6.2 GiB | Only by moving them |
| journal | 183 MiB | Now capped at 200M |

The real hazard is the local-path claims. `vmsingle` (10Gi request, 5.4 GiB used, 30d
retention) and `immich-model-cache` (10Gi request, 786 MiB used) total **20 GiB of claims
on a disk with ~7 GiB free**. local-path is a plain hostPath directory and enforces no
quota, so nothing stops either from filling root. Kubernetes believes both claims are
satisfiable; the disk disagrees.

Filling root means kubelet DiskPressure and eviction on the node that holds every workload
and every Longhorn replica.

**Prevention, in order:**

1. **Repoint local-path's storage directory onto `vdb`** (492 GiB, 23% used). Note the
   mechanism, because the obvious one does not stick: the `local-path-config` ConfigMap in
   `kube-system` is owned by k3s (`objectset.rio.cattle.io` annotations) and is re-applied
   from `/var/lib/rancher/k3s/server/manifests/` on every k3s restart, so editing it is
   reverted. The durable knob is the k3s server flag `--default-local-storage-path`, set in
   `/etc/rancher/k3s/config.yaml` (see item below on why not the systemd unit).

   This keeps the volumes on local-path rather than promoting them to Longhorn, which
   matters: ADR 005 puts monitoring data on local-path deliberately, because it is
   regenerable and should not consume Longhorn replicas or `vdb`'s replica budget. The fix
   is moving where local-path *lives*, not which class the PVCs use.

   One coupling to weigh: local-path data under `/mnt/longhorn` shares a filesystem with
   Longhorn replicas, so its growth reduces Longhorn's `storageAvailable`. Either use a
   sibling directory on `vdb` outside the Longhorn path, or accept it given 363 GiB free.
   A separate `vdc` is the clean separation if Proxmox access is convenient.

2. Move `/var/lib/rancher/k3s/agent/containerd` to `vdb`. Largest single win at 24 GiB,
   costs a k3s restart.
3. Grow `vda`. Needs Proxmox host access.

`DiskFillingUp` already fires on this and did during the incident, so the warning path works.

---

## 3b. Config that no GitOps mechanism reapplies

**Severity: medium. The failure mode is a rebuild that silently comes back wrong.**

ArgoCD covers `k8s/`. Three classes of configuration sit outside it, in descending order of
how well they are protected:

| Layer | Current mechanism | Survives |
|---|---|---|
| App manifests, alert rules, StorageClasses for apps | ArgoCD, self-healing | everything |
| Longhorn settings, replica count, disk reservation | imperative patches in `cluster-rebuild.md` §3 | a documented rebuild, if someone follows it |
| k3s server flags | `ansible/roles/k3s_node` → `/etc/rancher/k3s/config.yaml` | a k3s reinstall (the installer does not overwrite it) |
| Worker OS config (journald cap, iSCSI ordering) | `ansible/roles/{common,longhorn_node}` | an Ansible run — but nothing runs it on a schedule |

The Longhorn row has already failed once in a way that matters. `numberOfReplicas` silently
stayed at 3 for months because the StorageClass knob was missed, and every volume sat
degraded with replicas on the control node's OS disk. Documentation is not self-healing.

**Prevention:**

1. **Longhorn as an ArgoCD Application — written, not yet adopted.**
   `k8s/infrastructure/longhorn.yaml` now exists, pinned to chart 1.11.2 and matching the
   `victoria-metrics.yaml` pattern. It declares everything currently patched by hand:
   `defaultReplicaCount`, `storageReservedPercentageForDefaultDisk`,
   `storageOverProvisioningPercentage`, and `persistence.defaultClassReplicaCount` (the
   StorageClass knob that drifted).

   **It carries no `syncPolicy.automated`, on purpose.** Every other app in
   `k8s/infrastructure/` self-heals; this one must not, because the parent `infrastructure`
   app auto-syncs and would otherwise Helm-apply over a live Longhorn holding 11 volumes.
   The Application object gets created on commit; nothing reaches the cluster until someone
   syncs deliberately. Do not "Sync All" while it shows OutOfSync.

   Adoption is a maintenance-window job: verify volumes healthy, diff, sync, re-check the
   disk `Schedulable` condition, then delete the now-stale imperative patches from
   `cluster-rebuild.md` §3. Verify the chart's value key names first — Longhorn has renamed
   `defaultSettings` keys across minor releases.

   A useful side effect while it sits unsynced: the diff is a live inventory of how far the
   hand-install has drifted from the declared state.
2. **Move k3s server flags into `/etc/rancher/k3s/config.yaml`.** k3s reads it on every
   start and the installer does not overwrite it, so flags survive a reinstall. Today they
   exist only in the systemd unit that the original curl command generated.
3. **Worker OS config now has an owner: `ansible/`.** Three narrow roles cover the journald
   cap, `/etc/rancher/k3s/config.yaml`, and the `k3s-agent`↔iSCSI shutdown ordering. Run
   `ansible-playbook -i inventory.ini site.yml --check --diff` before applying.

   Two caveats worth keeping in view. The playbook is committed but **has not been executed
   yet** — Ansible is not installed on the workstation, so it is validated YAML with
   verified host assumptions, not an exercised run. And it is pull-on-demand: nothing runs
   it on a schedule, so drift between runs is invisible. That is acceptable at two nodes;
   it stops being acceptable if a third appears.

   Proxmox VM definitions remain out of scope, with the reasoning in `ansible/README.md`.

## 4. Worker memory limits are 191% of allocatable

**Severity: medium. Silent until several workloads peak together.**

```text
k3s-worker1   memory requests 5979Mi (50%)   limits 22820Mi (191%)
```

Requests are comfortable, so scheduling is honest. Limits are not: if enough workloads
approach their ceilings at once, the node has no way to satisfy them and the kernel starts
killing. `KubeMemoryOvercommit` and `KubeCPUOvercommit` have both been firing since
2026-07-25 20:27.

Immich alone holds a 3Gi limit and has already been OOMKilled once at 2Gi, so the limits
are not obviously wrong individually. The sum is the problem.

**Prevention:** this is a capacity decision, not a bug. Either accept it explicitly (single
worker, workloads rarely peak together, ~4.5 GiB currently available) or bring the sum
under 100% by trimming the largest limits. Worth recording which, so the alert stops being
ambient noise. `docs/reference/capacity-headroom.md` has the sizing context.

---

## 5. Every Longhorn volume depends on one node

**Severity: medium by design, and the design is deliberate.**

All 11 volumes are `numberOfReplicas: 1` on `k3s-worker1`. Redundancy lives at the ZFS
layer instead (ADR 012). The monitoring stack that would report a failure also runs on that
worker.

This is a considered trade, not an oversight, but it sets the blast radius for everything
above: one node event takes out all storage, and the observer with it.

**Prevention:** none proposed. Recorded so the consequence is explicit when the next
single-node event happens.

---

## 6. Shutdown ordering tears iSCSI out from under live volumes

**Severity: medium. Triggers item 1.**

A hypervisor-initiated shutdown stopped `open-iscsi` while containerd was still working
through its stop timeout, dropping 12 iSCSI sessions under mounted, actively-written
volumes. The kernel logged `potential data loss!` on every device. The replicas survived
intact this time. That was luck, not design.

**Prevention:** order `open-iscsi` to stop after kubelet and containerd, raise the container
stop grace period, and drain the node before `qm shutdown` rather than issuing it cold.

---

## 7. Longhorn volumes hold ~40 GiB of untrimmed blocks

**Severity: low. Hygiene, not a threat.**

Longhorn `actualSize` runs well ahead of real filesystem usage, and only three snapshots
exist, so this is unreclaimed blocks rather than snapshot retention:

| Volume | Filesystem used | Longhorn actual | Gap |
|---|---|---|---|
| nextcloud-data | 25 GiB | 42 GiB | 17 GiB |
| immich-library | 25 GiB | 44 GiB | 19 GiB |
| act-runner-data | 84 KiB | 4.99 GiB | ~5 GiB |

The only recurring job configured is `daily-snapshot` (retain 7). There is no `trim` job.

This does not affect scheduling, which uses provisioned size, and `/mnt/longhorn` has
363 GiB free. It does inflate rebuild and backup work.

**Prevention:** add a `trim` recurring job alongside the snapshot job.

---

## 8. Restore has been tested once

**Severity: low probability, total consequence.**

Backups are in good shape. restic to Backblaze B2, daily, `nextcloud` / `gitea` / `immich` /
`paperless`, all reporting success, 102 snapshots in the nextcloud repo, and verified
working against the salvaged volumes on 2026-07-26. Longhorn's own backup target is
separately unconfigured (`backuptargets/default` empty, `available: false`), which is fine
given restic covers the data.

The gap is exercise, not coverage. The last recorded test-restore was 2026-06-12.

**Prevention:** keep the quarterly test-restore cadence. A backup verified only by its own
exit code is a backup with one untested dependency.

---

## Cleared during this review

- `journald` had no cap and defaults to 10% of the filesystem (~4 GiB). Now capped at 200M
  in `/etc/systemd/journald.conf`.
- 70 exited containers and 4 orphaned images removed; apt cache cleared. Root went 84% to 82%.
- Certificates all valid, earliest expiry 2026-09-10 (`henrydowd-dev`), cert-manager renewing.
- Control node has room: 29% disk, 2.2 GiB memory available.
