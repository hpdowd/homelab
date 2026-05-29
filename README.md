# homelab

Personal homelab running on a Dell Optiplex (i5-14500T, 24GB RAM, ZFS RAID-1) managed with Proxmox.

Services are orchestrated via a k3s Kubernetes cluster, with GitOps managed by ArgoCD. Persistent storage is handled by Longhorn. Public services are exposed via Cloudflare Tunnels through a Traefik ingress controller.

## Infrastructure

| Component | Role |
|---|---|
| Proxmox | Hypervisor |
| k3s | Kubernetes distribution (control: 192.168.1.10, worker: 192.168.1.11) |
| ArgoCD | GitOps continuous delivery (app-of-apps pattern) |
| Longhorn | Persistent block storage (data on dedicated 500GB vdb) |
| MetalLB | LoadBalancer for bare-metal (IP pool: 192.168.1.200–210) |
| Traefik | Ingress controller (192.168.1.200) |
| Sealed Secrets | Encrypted secrets committed to git |
| cloudflared | Cloudflare Tunnel — wildcard *.henrydowd.dev → Traefik |
| Technitium | Internal DNS (*.lan and *.henrydowd.dev → 192.168.1.200) |
| WireGuard | VPN (endpoint: home.henrydowd.dev) |

## Services

| Service | LAN | Public | Backend |
|---|---|---|---|
| Gitea | gitea.lan | git.henrydowd.dev | k3s pod |
| Nextcloud | nextcloud.lan | nextcloud.henrydowd.dev | LXC 104 |
| Kiwix | wiki.lan | wiki.henrydowd.dev | LXC 109 |
| AMP | amp.lan | amp.henrydowd.dev | LXC 102 |
| Proxmox | proxmox.lan | proxmox.henrydowd.dev | Proxmox host |

## Repo Structure

```
homelab/
├── docs/
│   ├── caddy/          # Caddyfile reference (pre-migration)
│   └── technitium/     # DNS zone exports
└── k8s/
    ├── argocd/         # Root ArgoCD app (app-of-apps)
    ├── infrastructure/ # MetalLB, Traefik, cloudflared
    └── apps/           # Per-service manifests (Gitea, Nextcloud, Kiwix, AMP, Proxmox)
```

## Routing

All `*.henrydowd.dev` public traffic: Cloudflare → cloudflared tunnel → Traefik → service

All `*.lan` LAN traffic: Technitium DNS → Traefik (192.168.1.200) → service

Services not yet in k3s use a Service + EndpointSlice + Ingress pattern to proxy through Traefik to their LXC IP.
