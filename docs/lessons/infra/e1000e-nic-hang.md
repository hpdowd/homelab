# Incident: e1000e NIC "Hardware Unit Hang" — host unreachable, hard reboot required

## Date
2026-06-06

## Time lost
~1h (plus an overnight outage)

## Status
Mitigated — durable multi-layer fix identified, offload workaround applied.

## Context
- **System / component:** Proxmox VE host (`pve`), Dell Optiplex, i5-14500T. Onboard
  Intel NIC `enp0s31f6` (e1000e driver, PCI `0000:00:1f.6`).
- **Scope:** Host-wide. The NIC is the single uplink, so loss of it takes down the
  Proxmox web UI, all VMs/LXCs, k3s, and remote access simultaneously.
- **State before:** Idle overnight. No deploy in flight. (Monitoring stack had been
  deployed earlier the same day — this was a red herring, see Investigation.)

## Symptoms
- Server became completely unreachable on the LAN overnight. Could not reach the
  Proxmox web UI or SSH. Required a long-press power-off to recover.
- Previous boot's kernel log showed, repeating every ~2 seconds:
  ```text
  e1000e 0000:00:1f.6 enp0s31f6: Detected Hardware Unit Hang:
    ... MAC Status <40080043> PHY Status <796d> ...
  ```
- The repeating message is the driver failing to recover a hung TX ring.

## Investigation
- **Hypothesis 1 — memory exhaustion / OOM.** Initial suspicion, because the host
  had been running near its RAM ceiling and swap was already in use. **Ruled out:**
  `journalctl | grep -iE "oom|out of memory"` returned nothing, and ZFS ARC was
  already capped (`zfs_arc_max` = 2.3 GiB). No OOM-killer activity at all.
- **Hypothesis 2 — NIC driver hang.** Confirmed by the previous-boot log: the
  `Detected Hardware Unit Hang` spam is unambiguous and matches a long-standing
  e1000e bug on Intel I219/onboard NICs. The host wasn't dead — its network
  interface was wedged, which is why the console would have been fine but the LAN
  was silent.

## Root cause
Known e1000e transmit-unit hang on Intel onboard NICs. The driver's TX ring stalls
and the driver cannot self-recover; the interface goes silent until reset/reboot.
Aggravated by NIC hardware offloading and aggressive PCIe/NIC power management
(ASPM, EEE).

## Fix
**Immediate (applied) — disable offloading:**
```bash
ethtool -K enp0s31f6 gso off gro off tso off
```
Persisted via a oneshot systemd service so it survives reboots:
```bash
cat > /etc/systemd/system/fix-e1000e.service << 'EOF'
[Unit]
Description=Disable e1000e NIC offloading to prevent Hardware Unit Hang
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/sbin/ethtool -K enp0s31f6 gso off gro off tso off
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now fix-e1000e.service
```

**Durable (recommended, not yet applied) — driver + kernel power-management:**
Offload-off alone does not fix every case. The more permanent fix disables the
power-management features that trigger the hang:
```bash
# Driver level
echo "options e1000e EEE=0 InterruptThrottleRate=3000" > /etc/modprobe.d/e1000e.conf
update-initramfs -u
# Kernel level — disable PCIe Active State Power Management
# add pcie_aspm=off to GRUB_CMDLINE_LINUX_DEFAULT in /etc/default/grub, then:
update-grub
# BIOS (if it still recurs): disable ASPM, EEE, and CPU C-States.
```

## Verification
```bash
ethtool -k enp0s31f6 | grep -E "tcp-segmentation|generic-segmentation|generic-receive"
# all three: off
dmesg | grep -i e1000e        # no "Hardware Unit Hang" after the fix
```
Confirm sustained uptime under network load over several days — previous failures
recurred every few days.

## Prevention
- Offload-disable service in place; apply the driver+kernel layer for permanence.
- **Hardware fallback:** if it recurs after the full software fix, install a
  dedicated PCIe NIC (Intel i210/i350 or Realtek RTL8125) and disable the onboard.
- **Observability gap exposed:** because everything runs on this one host, the NIC
  hang blinded all monitoring too — there was no out-of-band way to see *why* the
  box was down. See the "second/guardian node" note in infrastructure backlog.

## Related
- This was misdiagnosed as a memory issue first; the lesson is to **pull the
  previous-boot kernel log before theorising** (`journalctl -b -1 -e`).
- Monitoring cannot observe its own host dying — ADR on host-level node-exporter
  (external scrape target) is the partial fix; a second node is the real one.
