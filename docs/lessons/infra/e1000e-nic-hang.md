# Incident: Intel I219-LM NIC "Hardware Unit Hang" — host unreachable, hard reboot required

## Date
2026-06-06

## Time lost
~1h (plus an overnight outage)

## Status
Resolved. Three-layer fix applied and verified.

## Context
- **System / component:** Proxmox VE host (`pve`), Dell Optiplex i5-14500T.
  Onboard Intel I219-LM NIC, `enp0s31f6`, e1000e driver, PCI `0000:00:1f.6`.
- **Scope:** Host-wide. This NIC is the single uplink — loss of it takes down
  the Proxmox web UI, all VMs/LXCs, k3s, and remote access simultaneously.
- **State before:** Idle overnight. Monitoring stack had been deployed earlier
  the same day (initially suspected as the cause — see Investigation).

## Symptoms
- Server completely unreachable on the LAN overnight. Could not reach the
  Proxmox web UI or SSH from any device. Required a long-press power-off to
  recover.
- Previous boot's kernel log showed the following, repeating every ~2 seconds:
  ```text
  e1000e 0000:00:1f.6 enp0s31f6: Detected Hardware Unit Hang:
    TDH <d>  TDT <90>  next_to_use <90>  next_to_clean <c>
    MAC Status <40080043>  PHY Status <796d>
  ```
- The driver was trying and failing to recover the TX ring, logging every 2s
  until the host was power-cycled.

## Investigation
- **Hypothesis 1 — memory exhaustion / OOM.** Initial suspicion given the host
  had been running near its RAM ceiling and swap was already in use. Ruled out:
  `journalctl | grep -iE "oom|out of memory"` returned nothing. ZFS ARC was
  already capped (`zfs_arc_max` = 2.3GiB). No OOM-killer activity at all.
  The monitoring stack was a red herring — the NIC hang would have occurred
  regardless of workload.
- **Hypothesis 2 — NIC driver hang.** Confirmed by pulling the previous boot's
  kernel log: `journalctl -b -1 -e`. The "Detected Hardware Unit Hang" spam is
  unambiguous. The host was not dead — its NIC was wedged, which is why the
  machine was unreachable but would have responded on the console.

  **Lesson from this investigation:** pull `journalctl -b -1 -e` before forming
  any theory. The correct cause was visible in 10 seconds; the memory hypothesis
  wasted significant time.

## Root cause
Known e1000e transmit-unit hang on Intel I219-LM onboard NICs. The driver's TX
ring stalls and the driver cannot self-recover; the interface goes silent until
the host is rebooted. Aggravated by NIC hardware offloading (TSO/GSO/GRO) and
PCIe/NIC power management features (ASPM, EEE). A known, long-standing bug
affecting the I219 family under Linux.

## Fix

Three layers applied, from most targeted to most systemic:

**Layer 1 — Disable NIC offloading (ethtool, persistent via systemd):**
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

**Layer 2 — Disable EEE and set conservative interrupt throttling (driver level):**
```bash
echo "options e1000e EEE=0 InterruptThrottleRate=3000" \
  > /etc/modprobe.d/e1000e.conf
update-initramfs -u
```

**Layer 3 — Disable PCIe Active State Power Management (kernel level):**
```bash
# In /etc/default/grub, change:
GRUB_CMDLINE_LINUX_DEFAULT="quiet pcie_aspm=off"
# Then:
update-grub
reboot
```

## Verification
Post-reboot `dmesg | grep -i e1000e` confirmed clean — normal driver init only,
no "Hardware Unit Hang":
```text
[0.994498] e1000e: Intel(R) PRO/1000 Network Driver
[1.263062] e1000e 0000:00:1f.6 eth0: (PCI Express:2.5GT/s:Width x1) ...
[1.309024] e1000e 0000:00:1f.6 enp0s31f6: renamed from eth0
[25.501897] e1000e 0000:00:1f.6 enp0s31f6: NIC Link is Up 100 Mbps Full Duplex
```

All three fix layers confirmed active:
```bash
ethtool -k enp0s31f6 | grep -E "tcp-segmentation|generic-segmentation|generic-receive"
# tcp-segmentation-offload: off
# generic-segmentation-offload: off
# generic-receive-offload: off

systemctl status fix-e1000e.service   # active (exited)
cat /etc/modprobe.d/e1000e.conf       # options e1000e EEE=0 InterruptThrottleRate=3000
grep pcie_aspm /etc/default/grub      # GRUB_CMDLINE_LINUX_DEFAULT="quiet pcie_aspm=off"
```

## Prevention
- Three-layer fix is in place. If hangs recur despite all three layers, the
  permanent hardware fix is a dedicated PCIe NIC (Intel i210/i350 or Realtek
  RTL8125) — onboard I219-LM has driver-level issues that software mitigations
  may not fully eliminate in all kernel versions.
- **Observability gap exposed:** the NIC hang blinded all monitoring too — there
  was no out-of-band way to see why the box was down until physically at it.
  A second low-power node for DNS/monitoring/remote access (or at minimum a
  host-level node-exporter scraped as an external target) would give earlier
  warning.

## Related
- HOMELAB.md Hardware section — NIC row documents fix state
- ADR 005 (`docs/adr/005-victoria-metrics-monitoring.md`) — monitoring cannot observe its own host dying
