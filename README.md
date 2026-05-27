# homelab

Personal homelab running on a Dell Optiplex (i5-14500T, 24GB RAM, ZFS RAID-1) managed with Proxmox.

Services are orchestrated via a k3s Kubernetes cluster, with GitOps managed by ArgoCD. Persistent storage is handled by Longhorn. Public services are exposed via Cloudflare Tunnels through a Traefik ingress controller.

## Structure

```
homelab/
├── docs/
│   ├── caddy/          # Caddyfile reference (pre-migration)
│   └── technitium/     # DNS zone exports
├── proxmox/
│   └── notes/          # VM specs and provisioning notes
└── k8s/
    ├── namespaces/
    ├── infrastructure/ # Traefik, ArgoCD, Longhorn, cloudflared
    └── apps/           # Nextcloud, Jellyfin, Gitea, Kiwix, AMP
```

## Infrastructure

| Component | Role |
|---|---|
| Proxmox | Hypervisor |
| k3s | Kubernetes distribution |
| ArgoCD | GitOps continuous delivery |
| Longhorn | Persistent block storage |
| Traefik | Ingress controller |
| cloudflared | Cloudflare Tunnel (WAN exposure) |
| Technitium | Internal DNS (*.lan) |
| WireGuard | VPN |

## Public Services

| Service | Domain |
|---|---|
| Nextcloud | nextcloud.henrydowd.dev |
| Gitea | git.henrydowd.dev |
| Kiwix | wiki.henrydowd.dev |
| AMP | amp.henrydowd.dev |
