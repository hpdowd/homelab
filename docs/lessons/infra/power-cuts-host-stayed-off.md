# Incident: Four power cuts, and a host that stayed off after every one

## Date
2026-09-02 to 2026-10-08 (diagnosed 2026-10-08)

## Time lost
Downtime: ~3h, ~1h, ~6h and ~45m, one per cut. Diagnosis: ~1h, most of it
chasing a host freeze that never happened.

## Status
Resolved. BIOS AC Recovery is now On, so the host powers itself back up.
The cuts themselves are outside the homelab's control.

## Context
- **System / component:** Proxmox host `pve`, Dell OptiPlex Micro 7020.
- **Scope:** everything; the host carries every guest.
- **State before:** idle each time.

## Symptoms
- Four boots that ended uncleanly: the journal simply stops, with no panic,
  OOM, NIC hang or shutdown sequence. `last -x` calls each a `crash`.
- Each outage lasted until someone pressed the power button.
- The firing alerts afterwards were only reboot fallout (`KubeJobFailed` from
  a cron run that raced Longhorn's CSI registration).

## Investigation
- **Hypothesis 1: host freezes, possibly a 7.0.14 kernel regression.**
  The logs could not rule it out, because a freeze and a power cut look the
  same in them: the journal just ends. The NIC-hang mitigations from June were
  all active, the VM metrics were flat going into every stop, and no
  throttling was ever logged. That made a silent freeze look plausible,
  and the shrinking gaps between events looked like degrading hardware.
  Wrong: 10-08 was a known power cut, and the WAN IP below shows the other
  three were too.
- **Firmware event logs:** no help. `dmidecode -t 15` is empty, and Dell's
  BIOS power log is only readable from the setup screen (sysfs exposes a
  `PowerLogClear` attribute and nothing to read).
- **The WAN IP, via the ddns log in the WireGuard LXC: conclusive.** The ISP
  rotates the address once a night, between about 01:00 and 06:00 UTC. A
  router reboot also gets a new one, and the router only reboots on a cut:
  ```bash
  ssh pve 'pct exec 101 -- cat /var/log/cloudflare-ddns.log'   # pct exec, never pct enter
  ```
  | Event | Host back (UTC) | New IP logged |
  |---|---|---|
  | 09-02 | 15:39 | 15:45 |
  | 10-01 | 13:48 | 13:50 |
  | 10-07 | 17:42 | 17:45 (that day's rotation was already done, 05:50) |
  | 10-08, confirmed cut | 19:22 | 19:25 |
  | 09-16, clean reboot (control) | 19:22 | no change |
  | 10-08, planned reboot (control) | 22:01 | no change |

  Each unexplained stop got a new IP at the first ddns run after boot; both
  host-only reboots did not.

## Root cause
Power cuts. The host stayed down for hours because BIOS **AC Recovery was
Off**: after power returned, the OptiPlex waited for its power button. The
current boot's SMBIOS `Wake-up Type: Power Switch` confirms a button press
started it.

## Fix
Set AC Recovery to On from Linux. The `dell-wmi-sysman` driver exposes BIOS
settings, and no BIOS admin password is set:
```bash
ssh pve 'echo On > /sys/class/firmware-attributes/dell-wmi-sysman/attributes/AcPwrRcvry/current_value'
```
It stays pending until the next POST (`pending_reboot` reads 1), so the host
was rebooted on purpose the same night to apply it.

## Verification
```bash
ssh pve 'A=/sys/class/firmware-attributes/dell-wmi-sysman/attributes;
  cat $A/AcPwrRcvry/current_value $A/pending_reboot'   # On, 0
```
Every guest already has `onboot: 1`, so when the host comes back, the
homelab follows it.

## Prevention
- **Ask about power before diagnosing a freeze.** Logs cannot tell the two
  apart. The ddns log can, in a minute.
- `ProxmoxHostRestarted` (homelab-rules) now announces every host restart,
  instead of leaving only the fallout alerts.
- Since 2026-10-09 a healthchecks.io dead-man's switch reports the homelab
  going dark about 11 minutes after it happens, by Pushover and email, and
  reports it back up when the pings resume (ADR 019). Those two messages also
  give the next outage a start and end time from outside the house.
- A small UPS would turn short cuts into nothing and long ones into a
  clean shutdown. Not bought yet.
- The reboot done to apply this setting is what exposed the unsafe worker
  shutdown: `storage/planned-reboot-longhorn-killed-under-writes.md`.

## Related
- `infra/e1000e-nic-hang.md`: the last time the host went silent, which was
  a different cause
- `infra/wireguard-lxc-dstate-freeze.md`: why it is `pct exec`, not `pct enter`
