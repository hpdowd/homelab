# Incident: All 11 Longhorn volumes faulted overnight, auto-salvage silently unable to recover

## Date
2026-07-26 (triggered 2026-07-25 19:29)

## Time lost
~16h of storage downtime, unattended overnight. ~1.5h diagnosis and recovery.

## Status
Resolved. All 11 volumes salvaged, filesystems and databases verified clean. The
underlying disk over-provisioning that blocked auto-salvage is **still present**,
see Prevention.

## Context
- **System / component:** Longhorn on k3s-worker1 (VM 301), data disk `/mnt/longhorn` (`/dev/vdb`, 492 GiB).
- **Scope:** every Longhorn volume in the cluster. All 11, across nextcloud, immich, gitea, paperless and kiwix.
- **State before:** normal running. A shutdown was issued from the hypervisor at 19:29, not from inside the guest.

## Symptoms
- Every volume `detached` / `faulted`, every replica `failedAt` within one second of the others:
  ```text
  pvc-04f933a1 ... detached  faulted   2026-07-25T18:34:49Z
  pvc-19898912 ... detached  faulted   2026-07-25T18:34:49Z
  (all 11, 18:34:48-49Z)
  ```
- Pods stuck in a mount loop for 16h:
  ```text
  MountVolume.MountDevice failed for volume "pvc-04f933a1-..." :
  rpc error: code = InvalidArgument desc = volume ... hasn't been attached yet
  ```
- Backup and cron jobs piled up against their deadlines. `nextcloud-backup` burned its full
  `activeDeadlineSeconds: 28800` and failed; `nextcloud-cron` failed every 5 minutes.
- Separately and misleadingly, kubelet was complaining about the OS disk:
  ```text
  FreeDiskSpaceFailed: Insufficient free disk space on the node's image filesystem
  (86% of 40.6 GiB used). Failed to free sufficient space by deleting unused images
  ```

## Investigation

The disk-space warning and the storage outage looked like one problem. They are not
related, and chasing the disk first wastes time.

- **Hyp 1: the OS disk filled and took Longhorn down.** Ruled out. Longhorn stores nothing
  on `/` (`/var/lib/longhorn` is 45 MiB, engine binaries and sockets only). Replica data lives
  on `/dev/vdb` at `/mnt/longhorn`, which was 23% used. The 86% figure is the OS disk and is a
  genuine but separate problem.
- **Hyp 2: the VM crashed or the kernel panicked.** Ruled out, and this one matters. The previous
  boot ends at 19:31:30 with no clean shutdown sequence, which reads like a crash. It was not.
  `journalctl -b -1` shows the actual initiator:
  ```text
  Jul 25 19:29:12 qemu-ga: info: guest-shutdown called, mode: (null)
  Jul 25 19:29:12 systemd-logind: System is powering down (hypervisor initiated shutdown)
  ```
- **Hyp 3: unattended-upgrades rebooted it.** Ruled out. No `/var/run/reboot-required`, empty
  `unattended-upgrades.log`, and the last apt action was `apt install ncdu` the day before.
- **Confirmed mechanism for the fault.** Containers did not stop within the timeout, then
  open-iscsi was torn down while volumes were still mounted and being written:
  ```text
  19:30:42 systemd: cri-containerd-...scope: Failed with result 'timeout'
  19:30:42 kernel: connection1..12:0: detected conn error (1020)
  19:30:42 kernel: EXT4-fs (sda): failed to convert unwritten extents to written extents
                   -- potential data loss!  (inode 262824, error -5)
  19:30:43 systemd: open-iscsi.service: Control process exited, code=killed, status=15/TERM
  ```
  Twelve iSCSI sessions dropped at once, so all 11 replicas failed in the same second.

- **The real question: why did it not recover?** A worker reboot on 2026-06-27 faulted every
  volume too and Longhorn `AutoSalvaged` its way out within minutes (see
  `k8s/worker-reboot-alert-storm.md`). This time it did not, and `auto-salvage` was `true`
  the whole time. The manager had been trying all night:
  ```text
  msg="All replicas are failed, auto-salvaging volume"  volume=pvc-04f933a1-...
  msg="Bringing up 0 replicas for auto-salvage"         volume=pvc-04f933a1-...
  ```
  4,367 attempts, every one bringing up **zero** replicas, never a non-zero count.

## Root cause

Two separate things, and the second is the one that turned a 5-minute blip into 16 hours.

**1. The fault.** A hypervisor-initiated shutdown stopped `open-iscsi` before containerd had
finished stopping containers. Pulling iSCSI out from under 11 live volumes fails every replica
simultaneously. With `numberOfReplicas: 1` (ADR 012, redundancy lives at the ZFS layer instead),
one failed replica means one faulted volume, so all 11 faulted at once.

**2. The non-recovery.** Longhorn's auto-salvage skips any replica whose disk is not
schedulable. The worker's data disk had been sitting at `Schedulable: False` with reason
`DiskPressure`:

```text
Scheduling space condition failed:
ScheduledTotal   = 376883380224 (Size + StorageScheduled)   351.0 GiB
is greater than
ProvisionedLimit = 369106904679 (100% of StorageMax - StorageReserved)  343.8 GiB
```

The arithmetic:

| Term | Bytes | GiB |
|---|---|---|
| StorageMaximum | 527,295,578,112 | 491.1 |
| storageReserved (30% default) | 158,188,673,433 | 147.3 |
| ProvisionedLimit (100% of max − reserved) | 369,106,904,679 | 343.8 |
| ScheduledTotal (sum of volume *spec* sizes) | 376,883,380,224 | 351.0 |

Over the limit by ~7.2 GiB. Longhorn schedules on **provisioned** size, not actual usage, so
the 200 GiB `immich-library` counts in full despite holding 41 GiB. On top of that,
`storage-reserved-percentage-for-default-disk` is 30, and that 30% was applied to a dedicated
492 GiB data disk where none of it is needed. Reserving 147 GiB of a disk that holds nothing but
Longhorn replicas is what pushed the total over.

So auto-salvage was enabled, was firing every 30 seconds, and was structurally incapable of
selecting a replica. Nothing alerted on it, because the disk condition had been `False` since
well before the reboot and nothing was failing while volumes stayed attached.

## Fix

Salvage clears `failedAt` on the replica, which is exactly what the UI's Salvage button does.
Done in tiers, smallest and least valuable first:

```bash
# canary: paperless-consume, 1 GiB, 49 MiB actual
kubectl -n longhorn-system patch replicas.longhorn.io \
  pvc-8bc5a202-10b1-4dd6-a6ac-8a6900d7c096-r-d6109e9f \
  --type=merge -p '{"spec":{"failedAt":""}}'

# then non-DB, then the three postgres volumes, then the two large ones
for r in <replica names in tier order>; do
  kubectl -n longhorn-system patch replicas.longhorn.io $r \
    --type=merge -p '{"spec":{"failedAt":""}}'
done
```

Each volume went `detached/faulted` to `attached/healthy` within about 30 seconds.

ArgoCD kept showing `nextcloud` and `paperless` as `Degraded` long after every pod was
healthy, and a hard refresh did not clear it. Two things were going on, and only the second
is the real one:

```bash
# 1. leftover Failed Job records from the outage window
kubectl -n nextcloud delete job nextcloud-backup-29750520 \
  nextcloud-cron-29751020 nextcloud-cron-29751025 nextcloud-cron-29751030
kubectl -n paperless delete job paperless-backup-29750610
```

That was not enough. ArgoCD 3.x assesses CronJob health by comparing timestamps on the
CronJob itself, so deleting the Job records changes nothing:

```text
nextcloud-backup   lastSchedule=2026-07-26T02:00:00Z  lastSuccessful=2026-07-25T02:05:27Z
paperless-backup   lastSchedule=2026-07-26T03:30:00Z  lastSuccessful=2026-07-25T03:30:18Z
nextcloud-cron     lastSchedule=2026-07-26T10:50:00Z  lastSuccessful=2026-07-26T10:50:03Z  (healthy)
```

`lastSuccessfulTime` older than `lastScheduleTime` reads as Degraded. It clears at the next
successful run, so either wait for tonight's schedule or force one, which also verifies the
backups still work against the salvaged volumes:

```bash
kubectl -n nextcloud create job nextcloud-backup-manual-recovery --from=cronjob/nextcloud-backup
kubectl -n paperless create job paperless-backup-manual-recovery --from=cronjob/paperless-backup
```

## Verification

```bash
# all 11 attached and healthy
kubectl -n longhorn-system get volumes.longhorn.io \
  -o custom-columns=PVC:.status.kubernetesStatus.pvcName,STATE:.status.state,ROBUST:.status.robustness

# filesystems clean: every device mounted with no journal recovery, no I/O errors
ssh k3s-worker1 "dmesg -T | grep -iE 'ext4|I/O error'"
#   EXT4-fs (sda..sdk): mounted filesystem ... r/w with ordered data mode
#   no "recovery complete", no I/O errors
```

That last check is the one that matters. The kernel logged `potential data loss!` during the
crash, so a clean mount with no journal replay is the evidence the replicas were consistent,
not an assumption.

Databases did textbook WAL crash recovery with no corruption:

```text
immich    LOG: database system was not properly shut down; automatic recovery in progress
          LOG: redo starts at 0/1D909898
          LOG: redo done at 0/1D909948
```

Data present after recovery: nextcloud 195 tables and 2,275 rows in `oc_filecache`,
paperless 74 tables, immich database 200 MB. No checksum or invalid-page errors in any of
the three.

Restic backups verified working against the salvaged volumes by triggering a run rather
than waiting for the schedule: `paperless` completed in 28s, `nextcloud` in 5m34s (in line
with its usual ~5m15s). Repo history intact at 102 snapshots, `nextcloud-data` steady around
24.6 GiB per daily snapshot. Both apps returned to `Healthy` on completion, and every ArgoCD
application is green.

## Prevention

**The disk is still over-provisioned, so auto-salvage is still blocked.** Until this is
fixed, the next hypervisor shutdown or host reboot reproduces the full 16-hour outage
instead of self-healing in minutes. Check with:

```bash
kubectl -n longhorn-system get nodes.longhorn.io k3s-worker1 \
  -o jsonpath='{range .status.diskStatus.*}{.conditions[?(@.type=="Schedulable")].status}{" "}{.conditions[?(@.type=="Schedulable")].reason}{"\n"}{end}'
# want: True   (currently: False DiskPressure)
```

Options, in order of preference:

1. Drop `storageReserved` on `/mnt/longhorn` from 147 GiB to something appropriate for a
   dedicated data disk. It is not the OS disk and does not need a 30% reservation. Reserving
   10% gives a 474 GiB limit against 351 GiB scheduled, which is comfortable headroom.
2. Right-size `immich-library`. 200 GiB provisioned against 41 GiB actual is most of the
   overshoot on its own.
3. Alert on the disk `Schedulable` condition. This was `False` for an unknown period before
   the reboot with no symptom, because it only bites when a replica needs scheduling, and
   auto-salvage is exactly that moment.

**Shutdown ordering.** `open-iscsi` must stop *after* kubelet and containerd, and the
hypervisor should drain the node before issuing a shutdown. A `qm shutdown` against this
worker currently guarantees the iSCSI teardown races live volumes.

**Alerting worked. Delivery is the gap.** Detection was never the problem, which is worth
stating plainly because it is the tempting wrong conclusion. Verified after the fact against
stored series:

```promql
# all 11 volumes, faulted == 1 for the whole window
max_over_time(longhorn_volume_robustness{state="faulted"}[17h] @ <outage>)

# and the alert did fire
max_over_time(ALERTS{alertname="LonghornVolumeDegraded"}[17h] @ <outage>)
#   alertstate="firing"
```

`LonghornVolumeDegraded` (critical, `for: 5m`) fired correctly, as did `DiskFillingUp`. The
metric carries a `state` label with per-state 0/1 series, so the expression is right. What
failed is that a critical alert at 19:34 on a Saturday goes to email and nothing escalates,
so eleven faulted volumes sat unattended for 16 hours. Fixing this means a channel that
interrupts (push/ntfy/Gotify) for `severity: critical`, not another rule.

**Separate, unresolved: worker OS disk at 84%.** Not a cause of this incident, but close to
the kubelet imagefs eviction threshold. It is not reclaimable garbage. 642 snapshot dirs
against 643 containerd records means nothing is orphaned, and `crictl rmi --prune` freed one
`pause` image. The 24 GiB is the extracted layers of 54 in-use images on a 41 GiB disk, which
is a sizing problem. `journalctl --vacuum-size=200M` recovered 348 MiB and that is all that
was available. Real options: move `/var/lib/rancher/k3s/agent/containerd` onto `vdb` (492 GiB,
23% used), move the 6.2 GiB of local-path PVs off root (5.4 GiB of it is VictoriaMetrics,
which should not be on the OS disk), or grow `vda`.

## Related
- Same trigger, opposite outcome (auto-salvage worked): `docs/lessons/k8s/worker-reboot-alert-storm.md`
- Why `numberOfReplicas: 1`: `docs/adr/012-keep-zfs-mirror-over-longhorn-redundancy.md`
- RWO attach behaviour for backup/cron pods: `docs/lessons/k8s/nextcloud-cron-multiattach-rwo.md`
- Backups that saved the risk profile here: nextcloud/immich/gitea/paperless restic to B2
