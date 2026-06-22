# Incident: Nextcloud AIO outage, Proxmox LXC firewall blocking port 11000

## Date
2026-05-28

## Time lost
~30m (short once firewall was suspected; time lost to checking app internals first)

## Status
Resolved.

## Context
- **System / component:** Nextcloud All-in-One (AIO) on LXC 104, pre-migration, before Nextcloud moved into the k3s cluster.
- **Scope:** Nextcloud only, the AIO Apache frontend listens on port 11000.
- **State before:** Reviewing and adjusting Proxmox firewall settings on the LXC.

## Symptoms
- Nextcloud became unreachable.
- The service was running inside the container; the failure was at the network-reachability layer.

## Investigation
- Application was up inside the LXC, so the problem was traffic not reaching it.
- The Proxmox firewall was enabled on the LXC (`firewall=1`) without an allow rule for port 11000, so inbound traffic was being dropped at the hypervisor level.

## Root cause
The Proxmox firewall was active on LXC 104 but had no allow rule for port **11000**, so nothing could reach the Nextcloud AIO Apache frontend. The container networking and the app were fine; the hypervisor-level firewall was silently dropping the traffic.

## Fix
- Added a firewall rule permitting port 11000 to the LXC.
- Hardened while there: restricted AIO admin ports 8080/8443 to the admin workstation IP only; left 3478 (Talk) closed since Talk is unused.

## Verification
Nextcloud reachable immediately after the rule was added. Admin ports confirmed reachable only from the intended IP.

## Prevention
- When enabling the Proxmox firewall on an LXC, it defaults to **dropping all inbound**. Every service port the container exposes needs an explicit allow rule.
- Document each container's required inbound ports alongside its firewall state so "firewall on, no rules" doesn't silently black-hole a service.

## Related
- Superseded context: Nextcloud has since migrated into k3s; ingress is now handled by Traefik, not the LXC firewall. The general lesson applies to every remaining LXC (Technitium, WireGuard, AMP).
