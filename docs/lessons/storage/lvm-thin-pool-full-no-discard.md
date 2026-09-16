# Incident: `pve/data` thin pool hit 100%, control plane froze mid-boot

## Date
2026-09-16

## Time lost
~2.5h of cluster downtime (~18:10 to ~20:56), ~45 min of diagnosis.

## Status
Resolved. Pool 100% → 71.10%; ~44.5 GiB more is staged behind a VM reboot.

## Context
- **System / component:** the `pve/data` LVM thin pool on `nvme0n1p3`, which backs
  every `local-lvm` guest disk: LXC 100 (Technitium), LXC 102 (AMP), VM 300
  (k3s-control) and VM 301 (k3s-worker1).
- **Scope:** both k3s VMs and the whole cluster. AMP took write errors but stayed up.
  Nothing on ZFS `tank` was affected.
- **State before:** the worker VM's RAM was being changed 14 → 12 GiB to free host
  memory for an AMP game server. That change is **not** what broke anything; it
  supplied the reboot that exposed a pool which had already filled.

## Symptoms
- `kubectl` hung on every call, `dial tcp 192.168.1.10:6443: i/o timeout`.
- VM 300 showed `status: running` in Proxmox but answered neither SSH nor the API.
  Its guest agent was gone and `qm status 300 --verbose` reported `free_mem` of
  4.94 GiB out of 5.09 GiB — a kernel up, and effectively no userspace.
- Its console was frozen 2.2 seconds into boot, the last lines being
  `/dev/vda2: recovering journal` then `/dev/vda2: clean`.
- The guest consumed **zero** CPU ticks over a 5-second sample: blocked, not spinning.
- On the worker, `k3s-agent` sat in `activating` for 30 minutes repeating
  `Failed to validate connection to cluster ... failed to get CA certs`.
- 52 pods in `Unknown`, every one of them on `k3s-worker1`.

## Investigation
The worker was the obvious suspect and was a dead end — it was up, healthy, idle at
429 MiB of 12 GiB, load 0.00, filesystem read-write, no I/O errors in its log. It
could not reach an API server that was not running. The failure was upstream of it.

The control plane's console gave the real shape of it. `recovering journal` followed
by `clean` means fsck read the disk, wrote its result, and got that far; boot then
stopped dead at 2.2s with the guest burning no CPU at all. A guest that is hung on a
lock spins. One blocked on I/O that never completes does exactly this.

Host `dmesg` then named it:

```text
EXT4-fs (dm-11): failed to convert unwritten extents to written extents
                 -- potential data loss!  (inode 2754818, error -5)
Buffer I/O error on device dm-11, logical block 15367683
```

`dm-11` is `pve-vm--102--disk--0`, the AMP container — the only ext4 on the pool the
*host* mounts directly, which is why it was the only one visible in host `dmesg`.
The VMs were failing identically, silently, one layer down.

```text
# lvs -a
LV     LSize    Data%  Meta%  Attr
data   <141.23g 100.00 4.29   twi-aotzD-

# dmsetup status pve-data-tpool
0 296173568 thin-pool 77 16184/376832 2313856/2313856 - out_of_data_space
  discard_passdown error_if_no_space - 1024
```

`2313856/2313856` data blocks, the `D` in the attr flags meaning the pool has failed,
and `error_if_no_space` meaning every write to every thin volume on it returns `EIO`.
Reads still work, which is precisely why fsck passed and the first write hung forever.

## Root cause

Two things, and only the second one is interesting.

**The proximate cause** is that the pool was over-provisioned — 163 GiB of thin
volumes on a 141 GiB pool — and AMP's growth finally consumed the last free block.

**The real cause is that none of the `local-lvm` guest disks had `discard=on`, so no
space freed inside any guest had ever been returned to the pool.** Comparing what the
pool believed it was holding against what the guests were actually using:

| Volume | Guest | Size | Pool held | Guest used | Dead |
|---|---|---|---|---|---|
| `vm-301-disk-1` | k3s-worker1 OS | 44G | 41.3G (93.81%) | **2.6G** | **~38.7G** |
| `vm-102-disk-0` | AMP | 61G | 56.5G (92.60%) | 47G | ~9.5G |
| `vm-300-disk-1` | k3s-control OS | 32G | 17.8G (55.50%) | 12G | ~5.8G |
| `vm-100-disk-0` | Technitium | 6G | 5.95G (99.22%) | 3.5G | ~2.4G |

Roughly 56 GiB of the 121.5 GiB in use was blocks nothing referenced. Over half the
pool was garbage.

The worker's 38.7 GiB has a specific and documented origin. On **2026-08-10**,
§3 of `docs/reference/known-risks.md` moved containerd (24 GiB) and local-path
(6.1 GiB) off `vda2` onto `vdb`, and recorded the win as the worker's OS disk going
**85% → 6%**. That number was true, and it was measured in the wrong layer. Inside
the guest ~30 GiB became free; at the host the thin pool never heard about it and
went on holding every block. The fix that was supposed to relieve disk pressure
quietly moved it one level down, where nothing was watching.

## Fix

The volume group had 16 GiB never allocated to anything, which bought the room to
work without touching guest data:

```bash
lvextend -L +14G pve/data          # pool 155.23G, 90.98%, attr back to twi-aotz--
qm stop 300 && qm start 300        # hung on EIO, would not shut down cleanly
```

Both nodes returned `Ready` and the worker's agent recovered on its own. 13 pods
stayed `Unknown` because their controllers could not replace them — all of ArgoCD
was wedged this way, single-replica Deployments whose dead pod still held the slot —
and needed `delete --force --grace-period=0`. Longhorn came back with all 12 volumes
`attached / healthy`; its data lives on `vdb` (ZFS) and was never at risk.

Then the actual reclamation:

| Action | Pool after |
|---|---|
| `lvextend -L +14G pve/data` | 90.98% |
| removed `vm-201-disk-0` (stopped QBittorrent VM, 20G at 99.2%) | 78.26% |
| `pct fstrim 100` — 2.2 GiB trimmed | — |
| `pct fstrim 102` — 13.2 GiB trimmed | **71.10%** |

`pct fstrim` works on a running container and needs no config change, because the
host holds the mount and the discard reaches LVM directly. The VMs are the problem
case and were set for next boot:

```bash
qm set 300 -virtio0 local-lvm:vm-300-disk-1,iothread=1,discard=on,size=32G
qm set 301 -virtio0 local-lvm:vm-301-disk-1,iothread=1,discard=on,size=44G
```

## Verification

Pool at 71.10%, state `rw`, metadata 3.88%. 69 pods Running, 12/12 Longhorn volumes
attached and healthy, every PVC bound.

**The `discard=on` flags are set but not yet in effect** — QEMU only picks them up at
VM start. This was confirmed rather than assumed, and the confirmation is the single
most useful thing in this document:

```text
before: 93.81        # lvs pve/vm-301-disk-1
k3s-worker1: fstrim -v /
/: 38 GiB (40844763136 bytes) trimmed
after:  93.81        # unchanged
```

The guest reports 38 GiB trimmed and the thin volume does not move. `lsblk -D` inside
the guest advertises `DISC-GRAN 512B` on `vda`, so everything looks supported and
`fstrim.timer` has presumably been "succeeding" nightly for months. Without
`discard=on`, QEMU accepts the discards and drops them. **There is no error and no
warning anywhere in this path.**

## Prevention

- **`discard=on` on every `local-lvm` disk, at creation.** Without it `fstrim` is
  theatre. The remaining ~44.5 GiB lands the next time VMs 300 and 301 are booted.
- **Never trust a guest-side disk figure as evidence about a thin pool.** `df` in the
  guest and `lvs` on the host answer different questions, and the 2026-08-10 entry
  celebrating "85% → 6%" is the worked example of reading the first as the second.
  Check both layers, or the number is decoration.
- **Watch the pool.** Nothing alerted. `DiskFillingUp` covers guest filesystems and
  saw nothing wrong, correctly — the guests had space. The pool went from healthy to
  total write failure with no signal at all, and the first symptom was a dead cluster.
  A `Data%` scrape off the Proxmox host is the missing check.
- **Set `thin_pool_autoextend_threshold`.** It is unset, and LVM warns about this on
  every `lvextend`. It is a weak net here (2 GiB of VG left) but it is free.
- **Keep the over-provisioning honest.** 163 GiB provisioned on a 155 GiB pool is
  still more than the disk has. That is workable, it is what thin provisioning is
  for, but it means the pool must be monitored rather than assumed.

## Related
- `docs/reference/known-risks.md` §3 — the 2026-08-10 move that stranded the blocks,
  and §7, the same untrimmed-block failure one layer up in Longhorn. Both are the
  same mistake in different storage layers.
- `docs/reference/gotchas.md`, "LVM thin pool (`local-lvm`)".
- AMP's rootfs took real write errors (`failed to convert unwritten extents`) before
  space was freed. It remounted read-write and writes fine, but an `fsck` on
  `vm-102-disk-0` is owed the next time LXC 102 is stopped.
