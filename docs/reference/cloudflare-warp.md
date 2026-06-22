# Cloudflare WARP on Arch + Wayland

WARP is configured here as a **backup remote-access path**; use it to reach the homelab or router UI when WireGuard or the router port-forward is down.

The WARP GUI fails to initialize on Wayland under a minimal tiling WM (no system tray). The daemon and CLI work fine. Use `warp-cli` exclusively; don't chase the GUI error.

## Setup

```bash
yay -S cloudflare-warp-bin
sudo systemctl enable --now warp-svc
warp-cli register      # first time only
warp-cli connect
```

## Modes

| Mode | Command | Use when |
|---|---|---|
| DNS-only | `warp-cli set-mode doh` | Just need Zero Trust DNS / name resolution |
| Traffic + DNS | `warp-cli set-mode warp` | Need to route into the private LAN through the Cloudflare connector |

## Common commands

```bash
warp-cli connect
warp-cli disconnect
warp-cli status
warp-cli settings
```

## Notes

- **Local Domain Fallback** (Zero Trust settings): routes `.lan` queries to Technitium when using WARP for private-network access, configure this so LAN hostnames resolve correctly over WARP.
- Zero Trust / Teams enrolment if needed: `warp-cli teams-enroll <team>.cloudflareaccess.com`
