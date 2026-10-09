# lxc

Files installed by hand in the Proxmox LXCs. No layer in this repo manages the
containers, so the copy here is the source. Each file's header says how to
install it.

| File | Container | Purpose |
|---|---|---|
| `wireguard/vpn-healthcheck.sh` | 101 (WireGuard) | Reports VPN health to the healthchecks.io check `homelab-vpn` every 5 minutes |

Use `pct exec` on LXC 101, never `pct enter` while on the VPN:
`docs/lessons/infra/wireguard-lxc-dstate-freeze.md`.
