# Incident: A planned host reboot killed Longhorn under live writes, again

## Date
2026-10-08

## Time lost
~1h diagnosis. ~10 min of cluster downtime, which was planned. No known data
loss beyond whatever paperless had in flight.

## Status
Resolved on both nodes. Proven by a test reboot of the worker the same
night; control loaded the same config via a k3s restart.

## Context
- **System / component:** k3s-worker1 (VM 301), Longhorn, and the
  `longhorn_node` systemd ordering written after the 2026-07-25 outage.
- **Scope:** every Longhorn volume on the worker.
- **State before:** a deliberate `reboot` of the Proxmox host to apply a BIOS
  setting (AC Recovery → On). That makes it a *graceful* shutdown, the case the
  July fix was supposed to make safe.

## Symptoms
- Proxmox's shutdown of VM 301 used the full 180s and then killed it:
  ```text
  VM 301 qga command 'guest-shutdown' failed - got timeout
  kvm: terminating on signal 15
  ```
- Inside the worker, every container scope was stopped in the same second, and
  the same second's log was flooded with:
  ```text
  systemd[1]: Failed to create inotify object: Too many open files
  ```
- 75s later, the paperless volume's engine was gone with celery still writing:
  ```text
  critical medium error, dev sdi, sector 280704 op 0x1:(WRITE)
  Aborting journal on device sdi-8.
  EXT4-fs (sdi): Remounting filesystem read-only
  iscsid: session 9 in invalid state for logout. Try again later   (x246)
  ```
- After boot, all 11 attached volumes came up `faulted` and Longhorn salvaged
  them. All 12 were `attached/healthy` about 10 minutes after boot.

## Investigation
- **Hypothesis 1: the guest agent never received the shutdown.** Ruled out:
  `qemu-ga` logged `guest-shutdown called` at 22:56:40, and logind logged
  "System is powering down (hypervisor initiated shutdown)". Proxmox's "got
  timeout" means the VM was still not off after 180s, not that the agent was
  silent.
- **Hypothesis 2: the July ordering drop-ins were missing.** Ruled out:
  `10-iscsi-order.conf` and `20-stop-timeout.conf` are both in place, and
  `systemctl show k3s-agent -p After` lists `open-iscsi.service
  iscsid.service`.
- **Confirmed: the ordering governs the wrong unit.** `k3s-agent` has
  `KillMode=process`. Containers live in their own `cri-containerd-*.scope`
  units, outside its cgroup. Ordering k3s-agent before iSCSI says nothing about
  when those scopes stop, and with nothing ordering them, systemd stops them all
  at once. Longhorn's instance-manager is one of those scopes.

## Root cause
Nothing stopped the pods in order. k3s ships the kubelet with
`shutdownGracePeriod: 0s`, which disables graceful node shutdown entirely. So
the only thing stopping pods was systemd tearing down every container scope in
parallel. The engines serving the volumes died alongside the apps writing to
them, and the mounts were left on a dead iSCSI transport that could neither
flush nor log out.

The July fix was correct about direction (k3s-agent before iSCSI) and wrong
about scope (k3s-agent is not where the containers are).

## Fix
`ansible/roles/k3s_node` writes
`/var/lib/rancher/k3s/agent/etc/kubelet.conf.d/50-graceful-shutdown.conf`,
which turns on the kubelet's graceful shutdown ordered by pod priority.
The values come from `k3s_shutdown_grace_by_priority` in `group_vars/all.yml`:

| Priority from | Who | Seconds |
|---|---|---|
| 0 | every app | 90 |
| 1000000000 | `longhorn-critical` (instance-manager, CSI) | 60 |
| 2000000000 | system-cluster/node-critical | 20 |

Supporting changes:
```bash
# Proxmox must outlast the 170s the kubelet holds the shutdown for (by hand;
# VM definitions are outside Ansible)
qm set 300 --startup order=2,up=30,down=300
qm set 301 --startup order=3,up=30,down=300
# load the kubelet config; KillMode=process, so no container restarts
systemctl restart k3s-agent      # on the worker
```
`roles/common` also raises `fs.inotify.max_user_instances` 128 → 8192 (and
watches → 524288), applied live. That was a separate defect, but the shutdown
is where it showed.

## Verification
Done:
```bash
ssh k3s-worker1 systemd-inhibit --list   # kubelet ... shutdown ... delay
ssh k3s-worker1 cat /etc/systemd/logind.conf.d/99-kubelet.conf   # InhibitDelayMaxSec=170
kubectl get --raw /api/v1/nodes/k3s-worker1/proxy/configz \
  | jq .kubeletconfig.shutdownGracePeriodByPodPriority
# restart counts identical before/after the k3s-agent restart; 12/12 volumes attached/healthy
```
Test reboot, `qm reboot 301 --timeout 300`, 2026-10-08 23:24:

| | Before (22:56, host reboot) | After (23:24, test) |
|---|---|---|
| guest-shutdown to power-off | 180s, then force-killed | 63s, clean |
| `critical medium error` / `Aborting journal` | yes, under paperless | 0 |
| `invalid state for logout` retries | 246 | 0 |
| open-iscsi stop | sessions still up under mounts | `No matching sessions found` |
| ext4 recovery on next mount | salvaged after write errors | none |
| volumes `attached/healthy` after boot | ~5 min | ~3 min |

The kubelet unmounted every Longhorn volume (14 `UnmountDevice succeeded`)
before systemd touched iSCSI.

Two things still happen, and both are expected:
- **Longhorn still reports volumes `faulted` with "Engine dead unexpectedly".**
  The kubelet *terminates* pods on shutdown but does not delete them, so no
  VolumeAttachment is ever released and Longhorn is never asked to detach.
  When instance-manager stops, the engine dies with the volume still
  nominally attached. The filesystem underneath was already unmounted, so the
  salvage is bookkeeping, not recovery. Avoiding even that would mean a
  `kubectl drain` before shutdown, which needs something to orchestrate it.
- **Terminated pods stay behind as `Failed`** ("Pod was terminated in response
  to imminent node shutdown") next to their running replacements, and pod GC
  does not remove them. They show as `Error` in `kubectl get pods` and confuse
  triage. Tonight's 15 were deleted by hand; since then the
  `node-maintenance/shutdown-pod-cleanup` CronJob does it every 10 minutes.
  It matches on reason *and* message, so failed Job pods (and their logs)
  are left alone.

## Prevention
- **A unit's ordering does not cover processes it does not own.** Before
  trusting an `After=` on a service, check its `KillMode`. If the real
  workload is in sibling scopes, the ordering does nothing for it.
- **"Graceful" host reboots were never safe.** July's outage was blamed on the
  shutdown's ordering, and the fix was never exercised by a real shutdown
  before this one. A shutdown-path fix is not done until a shutdown has run
  through it.
- The `ProxmoxHostRestarted` alert (2026-10-08) now makes every host restart
  visible, planned or not.

## Related
- `storage/longhorn-autosalvage-blocked-diskpressure.md`: the 2026-07-25 outage,
  same trigger
- `k8s/worker-reboot-alert-storm.md`
- `ansible/roles/longhorn_node/tasks/main.yml`: now notes the ordering is
  necessary but not sufficient
- Kubernetes docs: "Graceful node shutdown" / `shutdownGracePeriodByPodPriority`
