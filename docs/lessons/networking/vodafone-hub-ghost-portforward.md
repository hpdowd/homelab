# Incident: Vodafone Hub silently wiped port-forward rules (ghost rules in UI)

## Date
2026-05-27

## Time lost
~2h — the misleading UI sent debugging in the wrong direction

## Status
Resolved — root cause understood; rules re-created.

## Context
- **System / component:** Vodafone Ultra Hub (consumer router).
- **Scope:** Inbound port forwarding — specifically the WireGuard UDP port, which depends on a port-forward from the router to LXC 101.
- **State before:** Working remote access. Then DHCP range settings on the router were changed.

## Symptoms
- Remote access (WireGuard) stopped working from outside the LAN.
- The router's port-forwarding page **still showed the rules as present and valid** — so by inspection nothing looked wrong.
- Despite the rules appearing correct in the UI, no traffic was actually being forwarded.

## Investigation
- LAN-side everything was fine; the break was specifically inbound from WAN.
- The router UI was actively misleading: it displayed "ghost" rules that looked configured but had been silently invalidated.
- Correlated the breakage to the earlier DHCP range change.

## Root cause
Changing the DHCP range settings on the Vodafone Hub silently wiped the existing port-forward rules while continuing to display them in the UI as if active. The displayed configuration did not reflect actual forwarding state.

## Fix
Delete and re-create the port-forward rule(s) from scratch. Do not trust a rule that "looks fine" after any DHCP or network change on this router.

## Verification
Confirm the forward works from **outside** the LAN (mobile data, not Wi-Fi) — e.g. WireGuard handshake completes. UI presence is not proof.

## Prevention
- After any DHCP or network-settings change on the Vodafone Hub, re-verify port forwards from an external network. Treat the UI display as untrustworthy.
- This is a consumer-router limitation, not fixable in config. It's a reason the long-term plan avoids depending on this router for WAN exposure — Cloudflare tunnels sidestep it for HTTP services; only WireGuard's UDP port still needs the forward.

## Related
- `infra/wireguard-lxc-dstate-freeze.md` — WireGuard LXC operational notes
- The WireGuard UDP port-forward to LXC 101 is the only remaining dependency on this router for remote access
