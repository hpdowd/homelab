# homelab

Personal homelab running on a Dell Optiplex (i5-14500T, 24GB RAM, ZFS RAID-1) managed with Proxmox.

Services are orchestrated via a k3s Kubernetes cluster, with GitOps managed by ArgoCD. Persistent storage is handled by Longhorn. Public services are exposed via Cloudflare Tunnels through a Traefik ingress controller.

## Infrastructure

| Component | Role |
|---|---|
| Proxmox | Hypervisor |
| k3s | Kubernetes distribution (two nodes: control + worker) |
| ArgoCD | GitOps continuous delivery (app-of-apps pattern) |
| Longhorn | Persistent block storage on a dedicated 500GB disk |
| MetalLB | LoadBalancer for bare-metal (IP pool: 192.168.1.200–210) |
| Traefik | Ingress controller, single MetalLB-assigned VIP (192.168.1.200) |
| Sealed Secrets | Encrypted secrets committed to git |
| cloudflared | Cloudflare Tunnel — wildcard `*.henrydowd.dev` → Traefik |
| Technitium | Internal DNS — split-horizon for LAN and public hostnames |
| WireGuard | VPN for remote access |
| restic → B2 | Offsite backup — Backblaze B2, AES-256 encrypted, deduplicated |

## Services

| Service | LAN | Public | Backend |
|---|---|---|---|
| Gitea | gitea.lan | git.henrydowd.dev | k3s pod |
| Nextcloud | nextcloud.lan | nextcloud.henrydowd.dev | k3s pod |
| Kiwix | wiki.lan | wiki.henrydowd.dev | k3s pod |
| AMP | amp.lan | amp.henrydowd.dev | external LXC 102 (permanent) |
| Proxmox | proxmox.lan | proxmox.henrydowd.dev | hypervisor host (HTTPS skip-verify) |
| Technitium | technitium.lan | — | external LXC 100 |

External LXC services use a Service + EndpointSlice + Ingress pattern to proxy through Traefik.

## Repo Structure

```
homelab/
├── docs/
│   ├── adr/                    # Architecture Decision Records
│   │   └── 004-restic-b2-bckup.md
│   ├── caddy/CaddyFile         # reference (pre-migration)
│   ├── technitium/lan.zone     # DNS zone backup
│   └── restore-procedure.md   # DR runbook (Nextcloud + Gitea)
└── k8s/
    ├── argocd/                 # Root ArgoCD app (app-of-apps)
    ├── infrastructure/         # MetalLB, Traefik, cloudflared
    └── apps/
        ├── gitea/              # k3s pod + backup CronJob
        ├── nextcloud/          # k3s pod + Postgres + Redis + backup CronJob
        ├── kiwix/              # k3s pod
        ├── amp/                # external → LXC 102
        ├── proxmox/            # external → Proxmox host
        └── technitium/         # external → LXC 100
```

## Routing

All public traffic: Cloudflare → cloudflared tunnel → Traefik → service

All LAN traffic: Technitium DNS → Traefik VIP (192.168.1.200) → service

> See **CONTEXT.md** for cluster state, access commands, and deployment notes.
> See **PLAN.md** for the migration history, phase status, and upcoming work.
