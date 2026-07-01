# k8s/infrastructure

ArgoCD Applications for cluster-wide infrastructure — things every app depends on. Managed as a single `infrastructure` Application via `k8s/apps/infrastructure-app.yaml`.

| Resource | Purpose |
|---|---|
| metallb.yaml + metallb-config/ | Layer-2 load balancer, IP pool 192.168.1.200–210 |
| traefik.yaml | Ingress controller, holds the MetalLB VIP (192.168.1.200) |
| cert-manager.yaml | cert-manager chart: issues the Let's Encrypt wildcard cert via DNS-01 against Cloudflare |
| cert-manager-config.yaml + cert-manager-config/ | ClusterIssuer, wildcard Certificate for henrydowd.dev (wired to Traefik `default` TLSStore, ADR 007), plus a second wildcard Certificate for dowd.ie (loaded per-Ingress via `tls:` blocks, not the TLSStore) |
| cloudflared.yaml + cloudflared/ | Cloudflare Tunnel — public ingress for `*.henrydowd.dev` |
| victoria-metrics.yaml | Monitoring stack (vmsingle + Grafana + Alertmanager) |
