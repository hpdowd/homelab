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
| MetalLB | LoadBalancer for bare-metal (small reserved range on the LAN) |
| Traefik | Ingress controller, single MetalLB-assigned VIP |
| Sealed Secrets | Encrypted secrets committed to git |
| cloudflared | Cloudflare Tunnel — wildcard public hostname → Traefik |
| Technitium | Internal DNS (split-horizon for LAN and public hostnames) |
| WireGuard | VPN for remote access |

## Services

| Service | Backend |
|---|---|
| Gitea | k3s pod |
| Nextcloud | external LXC (migration pending) |
| Kiwix | external LXC (migration pending) |
| AMP | external LXC (permanent) |
| Proxmox | hypervisor host (proxied via Traefik IngressRoute) |

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

All public traffic: Cloudflare → cloudflared tunnel → Traefik → service

All LAN traffic: Technitium DNS → Traefik VIP → service

Services not yet in k3s use a Service + EndpointSlice + Ingress pattern to proxy through Traefik to their LXC IP.
