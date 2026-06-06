# Lessons (Incident Log)

Post-mortems filed after anything that caused downtime, data risk, or significant wasted time. Organised by domain:

- `infra/` — Proxmox host, hardware, networking below k3s
- `k8s/` — cluster-level issues (pods, controllers, storage)
- `networking/` — DNS, Traefik, cloudflared, tunnels
- `storage/` — Longhorn, ZFS, PVC issues
- `backup/` — restic, B2, restore failures

Use `TEMPLATE.md` for new entries. Each entry covers: date · context · symptoms · investigation (including dead ends) · root cause · fix · verification · prevention.

## Current entries

| File | Domain | Summary |
|---|---|---|
| infra/e1000e-nic-hang.md | infra | Intel onboard NIC TX ring stall — host unreachable, required hard reboot |
| infra/nextcloud-lxc-firewall-port11000.md | infra | Proxmox LXC firewall silently blocked port 11000 (AIO frontend) |
| infra/wireguard-lxc-dstate-freeze.md | infra | `pct enter` into WireGuard LXC while VPN active → D-state freeze, host reboot required |
| k8s/grafana-pvc-corruption.md | k8s | Reused Grafana PVC with corrupt SQLite across reinstalls → CrashLoopBackOff |
| networking/proxmox-502-selfsigned-tunnel.md | networking | Cloudflare tunnel returned 502 for Proxmox — self-signed cert on :8006 |
| networking/vodafone-hub-ghost-portforward.md | networking | Vodafone Hub silently wiped port-forward rules after DHCP change |
