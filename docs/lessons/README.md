# Lessons (Incident Log)

Post-mortems filed after anything that caused downtime, data risk, or significant wasted time. Organised by domain:

- `infra/` — Proxmox host, hardware, networking below k3s
- `k8s/` — cluster-level issues (pods, controllers, storage)
- `networking/` — DNS, Traefik, cloudflared, tunnels
- `storage/` — Longhorn, ZFS, PVC issues
- `backup/` — restic, B2, restore failures

Use `TEMPLATE.md` for new entries. Each entry covers: date · context · symptoms · investigation (including dead ends) · root cause · fix · verification · prevention.
