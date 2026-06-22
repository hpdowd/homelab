# Incident: WireGuard LXC frozen in D-state after `pct enter` over the VPN

## Date
2026-05-27

## Time lost
~1h+ (ended in a full host reboot)

## Status
Resolved, operational rule established to prevent recurrence.

## Context
- **System / component:** WireGuard VPN LXC (Alpine). At the time numbered **102**; later renumbered to **101** during a Proxmox inventory re-shuffle. Currently LXC 101.
- **Scope:** The WireGuard container itself, and ultimately the whole Proxmox host, the only recovery was a host reboot.
- **State before:** Connected to the homelab over the WireGuard VPN, then opened a shell into the WireGuard LXC from the Proxmox host with `pct enter`.

## Symptoms
- The container became unresponsive immediately after `pct enter`.
- The offending process was stuck in **uninterruptible sleep (D-state)**, `kill -9` had no effect.
- Normal container stop/restart did not recover it.

## Investigation
- The freeze coincided exactly with entering the container's namespace while the VPN tunnel was active.
- A D-state process means the task is blocked in a kernel call that can't be interrupted; signals don't reach it, which is why `kill -9` did nothing.

## Root cause
Entering the WireGuard LXC's network namespace (via `pct enter`) while the VPN was active created a routing loop / namespace conflict inside the kernel. The container networking wedged in a state that couldn't be unwound from userspace.

## Fix
No userspace action (kill, container stop, restart) could clear the D-state. **Only a full Proxmox host reboot recovered it.** The WireGuard LXC was subsequently rebuilt on Alpine with fresh keys and OpenRC autostart.

## Verification
Host rebooted, LXC came back, VPN connectivity restored after the rebuild. No recurrence once the rule below was followed.

## Prevention
**Standing operational rule:**
> Never `pct enter` the WireGuard LXC while connected to the VPN, and never SSH into it *through the tunnel itself*. Both can cause a network-namespace conflict that freezes the container in D-state and requires a host reboot.

If a shell inside it is needed, use a session that is **not** routed through the WireGuard tunnel, local LAN, or Proxmox host console with the VPN client disconnected.

## Related
- This rule is captured in `HOMELAB.md` under the WireGuard LXC section.
- D-state surviving `kill -9` is the diagnostic signature: if it recurs, skip further signal attempts and schedule a reboot immediately.
