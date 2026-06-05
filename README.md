# homelab

My homelab. Lives on one Dell Optiplex under the desk — Proxmox on the
metal, a tiny k3s cluster on top, most of my services in there.

This repo is the source of truth. ArgoCD watches `main` and reconciles
the cluster against it. If something's running and it isn't in here,
that's a bug.

## What runs here

Things I host for me: Gitea (this repo), Nextcloud (files, calendar,
contacts), Kiwix (offline Wikipedia), an AMP game server, the Proxmox
web UI, and Technitium for LAN DNS. The first three live in k3s.
AMP, Proxmox and Technitium stay on LXCs and get proxied through the
cluster's Traefik so the routing is uniform.

Public stuff comes in via a Cloudflare Tunnel — no port forwarding,
no exposed IP. LAN stuff goes through Technitium so the `.lan`
hostnames just work from inside the house.

## Where to look

- **[docs/architecture.md](docs/architecture.md)** — how the pieces
  fit together. Start here if you've never seen this repo before.
- **[docs/bootstrap.md](docs/bootstrap.md)** — what it takes to
  rebuild the cluster from a freshly installed Proxmox. The "if
  everything dies" runbook.
- **[docs/operations.md](docs/operations.md)** — the commands I
  actually run day to day. Sealing secrets, syncing apps, that kind
  of thing.
- **[docs/adding-a-service.md](docs/adding-a-service.md)** — pattern
  walkthrough for dropping in a new service.
- **[docs/restore-procedure.md](docs/restore-procedure.md)** — how to
  restore Nextcloud or Gitea from the offsite backups.
- **[docs/adr/](docs/adr/)** — short notes on the *why* behind
  certain decisions (backups, monitoring).

The non-obvious gotchas tend to live as comments inside the YAML
that caused them, rather than in a separate "gotchas" doc.

## Layout

```
homelab/
├── docs/         the prose
└── k8s/
    ├── argocd/        root-app — the only thing ArgoCD needs to be pointed at
    ├── infrastructure/   MetalLB, Traefik, cloudflared, VictoriaMetrics
    └── apps/             one directory per service
```

That's it. If you want the deep version of any of this, the docs
above go into it.
