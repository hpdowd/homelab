# homelab

My homelab. Lives on one Dell Optiplex under the desk — Proxmox on the
metal, a tiny k3s cluster on top, most of my services in there.

This repo is the source of truth. ArgoCD watches `main` and reconciles
the cluster against it. If something's running and it isn't in here,
that's a bug.

## What runs here

Things I host for me: Gitea (this repo), Nextcloud (files, calendar,
contacts), Collabora (in-browser docs for Nextcloud), Kiwix (offline
Wikipedia), an AMP game server, the Proxmox web UI, and Technitium for
LAN DNS. The first four live in k3s. AMP, Proxmox and Technitium stay
on LXCs and get proxied through the cluster's Traefik so the routing is
uniform. VictoriaMetrics + Grafana + Alertmanager runs in-cluster for
metrics, dashboards, and email alerts.

Public stuff comes in via a Cloudflare Tunnel — no port forwarding,
no exposed IP. LAN stuff goes through Technitium so the `.lan`
hostnames just work from inside the house.

Secrets are committed as **SealedSecrets** — encrypted against the
in-cluster controller's public key. The controller's private key is the
only trust root and is not in this repo.

## Where to look

**Reference**
- **[docs/reference/architecture.md](docs/reference/architecture.md)** — how the pieces fit together. Start here.
- **[docs/reference/services.md](docs/reference/services.md)** — what runs where, and the config facts each service depends on.
- **[docs/reference/gotchas.md](docs/reference/gotchas.md)** — the sharp edges, one paragraph each, linked to the full lessons.
- **[docs/reference/operations.md](docs/reference/operations.md)** — commands for day-to-day ops: ArgoCD, Sealed Secrets, ZFS, backup verification, diagnosis flow.

**Runbooks**
- **[docs/runbooks/cluster-rebuild.md](docs/runbooks/cluster-rebuild.md)** — rebuild from a freshly installed Proxmox. The "if everything dies" runbook.
- **[docs/runbooks/restore-procedure.md](docs/runbooks/restore-procedure.md)** — restore Nextcloud or Gitea from the offsite backups.
- **[docs/runbooks/adding-a-service.md](docs/runbooks/adding-a-service.md)** — pattern walkthrough for dropping in a new service.

**Architecture Decision Records**
- **[docs/adr/](docs/adr/)** — the *why* behind key decisions (backups, monitoring). Each ADR has a Status and Superseded By field.

**Incident log**
- **[docs/lessons/](docs/lessons/)** — post-mortems filed by domain (`infra/`, `k8s/`, `networking/`, `storage/`, `backup/`). Template at `docs/lessons/TEMPLATE.md`.

## Layout

```
homelab/
├── docs/
│   ├── adr/            architecture decision records
│   ├── lessons/        incident post-mortems by domain
│   ├── runbooks/       repeatable procedures
│   ├── reference/      cheat-sheets and architecture walkthrough
│   └── public-export-checklist.md
└── k8s/
    ├── argocd/         root-app — the only thing ArgoCD needs to be pointed at
    ├── infrastructure/ MetalLB, Traefik, cloudflared, VictoriaMetrics
    └── apps/           one directory per service
```
