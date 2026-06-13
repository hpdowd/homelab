# Resources — where everything comes from

Per-component pointers: where the chart/manifest lives, which registry the
images come from, where the docs and release notes are. **No versions here** —
versions live in the manifests, nowhere else:

```bash
grep -rn 'targetRevision\|image:' k8s/ | grep -v henrydowd   # what's pinned right now
```

## Platform

| Component | Deployed from | Images | Docs | Releases / issues |
|---|---|---|---|---|
| k3s | `get.k3s.io` install script on the VMs | (bundled) | [docs.k3s.io](https://docs.k3s.io) | [k3s-io/k3s](https://github.com/k3s-io/k3s/releases) |
| ArgoCD | raw `install.yaml` from the repo (see cluster-rebuild.md) | `quay.io/argoproj/argocd` | [argo-cd.readthedocs.io](https://argo-cd.readthedocs.io) | [argoproj/argo-cd](https://github.com/argoproj/argo-cd/releases) |
| Sealed Secrets | `controller.yaml` from GitHub releases | `docker.io/bitnami/sealed-secrets-controller` | the [repo README + docs/](https://github.com/bitnami-labs/sealed-secrets) — there is no separate docs site | [bitnami-labs/sealed-secrets](https://github.com/bitnami-labs/sealed-secrets/releases) — `kubeseal` CLI comes from the same release; keep it ≥ controller version |
| Longhorn | chart: `charts.longhorn.io` | `docker.io/longhornio/*` | [longhorn.io/docs](https://longhorn.io/docs) — **versioned, switch the picker to the deployed minor** | [longhorn/longhorn](https://github.com/longhorn/longhorn/releases); issues there too — good search hit-rate for volume weirdness |
| MetalLB | chart: `metallb.github.io/metallb` | `quay.io/metallb/*` + `quay.io/frrouting/frr` | [metallb.io](https://metallb.io) | [metallb/metallb](https://github.com/metallb/metallb/releases) |
| Traefik | chart: `helm.traefik.io/traefik` | `docker.io/traefik` | [doc.traefik.io/traefik](https://doc.traefik.io/traefik/) — **versioned**; CRD reference under Routing → Providers → Kubernetes CRD | [traefik/traefik](https://github.com/traefik/traefik/releases) — v2→v3 default changes have bitten twice (readTimeout, entrypoints) |
| cloudflared | raw manifest | `docker.io/cloudflare/cloudflared` | [Cloudflare Tunnel docs](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/) | [cloudflare/cloudflared](https://github.com/cloudflare/cloudflared/releases) |
| cert-manager | chart: `charts.jetstack.io` | `quay.io/jetstack/*` | [cert-manager.io/docs](https://cert-manager.io/docs/) — **versioned** | [cert-manager/cert-manager](https://github.com/cert-manager/cert-manager/releases) |
| VictoriaMetrics stack | chart: `victoriametrics.github.io/helm-charts` (`victoria-metrics-k8s-stack`) | `docker.io/victoriametrics/*`, `docker.io/grafana/grafana`, `docker.io/prom/alertmanager`, `quay.io/prometheus/node-exporter`, `registry.k8s.io/kube-state-metrics/*` | [docs.victoriametrics.com](https://docs.victoriametrics.com) — **operator section** for `VMRule`/`VMServiceScrape` CRD schemas | chart: [VictoriaMetrics/helm-charts](https://github.com/VictoriaMetrics/helm-charts/releases) · engine: [VictoriaMetrics/VictoriaMetrics](https://github.com/VictoriaMetrics/VictoriaMetrics/releases) — chart bumps can move Grafana/Alertmanager majors silently, diff `helm show values` |

## Apps

| Component | Deployed from | Images | Docs | Releases / issues |
|---|---|---|---|---|
| Gitea | raw manifests | `docker.io/gitea/gitea` | [docs.gitea.com](https://docs.gitea.com) | [go-gitea/gitea](https://github.com/go-gitea/gitea/releases) — breaking changes flagged in release blog |
| Gitea Actions runner | raw manifests (ADR 008) | `docker.io/gitea/act_runner` + `docker.io/docker` (dind sidecar); jobs run in `docker.io/catthehacker/ubuntu` | [docs.gitea.com](https://docs.gitea.com/usage/actions/overview) — `act_runner` config under Usage → Actions | [gitea/act_runner](https://gitea.com/gitea/act_runner/releases) — registers against the Gitea server; heavy builds offloaded to GitHub-hosted runners, see ADR 008 |
| Nextcloud | raw manifests | `docker.io/nextcloud` (official library image, `-apache` variant) | [admin manual](https://docs.nextcloud.com) — **versioned**; image-specific behavior in [nextcloud/docker README](https://github.com/nextcloud/docker) | [nextcloud/server](https://github.com/nextcloud/server/releases) — only ever step one major at a time |
| Collabora CODE | raw manifests | `docker.io/collabora/code` | [sdk.collaboraonline.com](https://sdk.collaboraonline.com) | [CollaboraOnline/online](https://github.com/CollaboraOnline/online/releases) |
| Kiwix | raw manifests | `ghcr.io/kiwix/kiwix-serve` | [kiwix/kiwix-tools](https://github.com/kiwix/kiwix-tools) | ZIM content (the part that actually changes): [library.kiwix.org](https://library.kiwix.org) |
| Immich | raw manifests (ADR 006) | `ghcr.io/immich-app/*` — incl. their vectorchord postgres build, pinned by digest | [immich.app/docs](https://immich.app/docs) | [immich-app/immich](https://github.com/immich-app/immich/releases) — **read the notes before every bump**, breaking changes are routine; server/ML/mobile versions move together. GitHub Discussions has the best debugging hit-rate |
| Postgres (nextcloud) | raw manifests | `docker.io/postgres` (official library) | [postgresql.org/docs](https://www.postgresql.org/docs/) | majors need `pg_upgrade`/dump-restore — never just bump the tag |
| Redis / Valkey | raw manifests | `docker.io/redis`, `docker.io/valkey/valkey` | — | cache-only here; any maintained tag is fine |

## Backup

| Component | Where | Docs |
|---|---|---|
| restic | installed at job runtime (`alpine` + apk in the backup CronJobs) | [restic.readthedocs.io](https://restic.readthedocs.io) · [restic/restic](https://github.com/restic/restic/releases) |
| Backblaze B2 | S3-compatible endpoint (see backup manifests) | [B2 docs](https://www.backblaze.com/docs) — lifecycle rules live here (open work item) |

## Planned

| Component | Images | Docs |
|---|---|---|
| Authelia (Phase 8) | `docker.io/authelia/authelia` (also on ghcr) | [authelia.com](https://www.authelia.com) — **versioned**; per-app integration guides under Integration → OpenID Connect → Clients |

## Finding and judging images / charts

- **Charts**: [Artifact Hub](https://artifacthub.io) for discovery, but always
  pin from the project's own repo URL, and verify the version exists with
  `helm search repo` (gotcha: never trust a version from memory).
- **Trust ladder for images**: project-owned registry (`ghcr.io/<project>`,
  `quay.io/<project>`, `registry.k8s.io`) → Docker official library image
  (`docker.io/<name>` with no namespace) → `linuxserver.io` repacks → random
  individuals' images (don't).
- **Docker Hub rate limits**: anonymous pulls are throttled per-IP. Normal
  operation never notices; a cluster rebuild pulling 40+ images in an hour
  can. If a rebuild hits `429`s, wait, or authenticate the pull.
- **Never `latest`, never floating majors** — every image and chart in this
  repo is pinned exactly; Immich's postgres/valkey are pinned by digest
  because upstream moves their tags.
- **CRD schema lookups** (the wrong-kind/wrong-key gotchas):
  Traefik `Middleware`/`IngressRoute`/`ServersTransport` → doc.traefik.io;
  `VMRule`/`VMServiceScrape` → docs.victoriametrics.com operator section;
  `SealedSecret` → bitnami-labs repo; `Certificate`/`ClusterIssuer` →
  cert-manager.io.

## Before an upgrade

1. Release notes for everything between current and target (not just the target).
2. Charts: `helm show values <chart> --version <target>` diffed against current
   rendered values — renamed/removed keys are dropped **silently**
   (`docs/lessons/k8s/argocd-comparisonerror-silent-values.md`).
3. Switch the docs site's version picker to the target before reading.
4. Render before committing, `argocd app get` after syncing — pods staying up
   proves nothing (same lesson).
5. Stateful apps (Nextcloud, Postgres, Immich): check whether the bump runs a
   migration; if yes, confirm last night's backup verified before syncing.
