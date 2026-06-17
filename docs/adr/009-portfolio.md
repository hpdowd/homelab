# ADR 009 — Portfolio site: Tier-3 single Go binary, GHCR image, GitHub-Actions build

**Status:** Accepted
**Date:** 2026-06-17
**Superseded By:** —

## What problem this solves

A personal portfolio/CV that runs as another service on the cluster — and
*demonstrates* the platform work by being instrumented and self-monitoring
(call it Tier 3) rather than just describing it. The requirements that drove the
design: public hosting on `henrydowd.dev`, a build/deploy path that fits the
GitOps model, live homelab data on the page, and **no secret on a
public-facing pod**.

## What I picked

1. **One static Go binary that embeds the built Astro site.** Two listeners:
   `:8080` public (the site + `/api/*`) and `:9090` private (`/metrics` +
   `/healthz`, never Ingress-routed). One image, one Deployment. Standard
   library only — the Prometheus exposition is hand-rolled — so there is no
   `go.sum`, a tiny static image (~3.3MB), and reproducible builds.
2. **No credentials in the public pod.** VictoriaMetrics has no auth, and the
   git-activity feed reads the **public** `henry/homelab` repo anonymously
   (`REQUIRE_SIGNIN_VIEW=false`). The public-facing service holds zero secrets.
3. **Image built by GitHub Actions, published to GHCR (public), pulled
   anonymously** — like Immich. The in-cluster `act_runner` can't build images
   (no Docker daemon reachable from job steps — see the lesson), and ADR 008
   already routes builds that don't belong on the worker to GitHub-hosted
   runners. The Gitea repo push-mirrors to GitHub (`hpdowd/portfolio`);
   `.github/workflows/build.yml` builds there, guarded `if: github.server_url
   == 'https://github.com'` so the Gitea mirror skips it.
4. **Apex `henrydowd.dev` (+ `www`)** — the one service on the bare domain.
   Needed its own cloudflared route + Technitium apex A record (the
   `*.henrydowd.dev` wildcard doesn't match the zone root); TLS was already in
   the LE wildcard SAN.
5. **Recursive scrape.** A `VMServiceScrape` targets the binary's `/metrics`, so
   the service that surfaces homelab telemetry is itself a monitored target in
   the same stack — the self-demonstrating payoff.

## What I rejected

- **Two processes (nginx static + a separate Go API).** Doubles the deploy
  surface for failure-isolation we bought more cheaply (memory limit + recovered
  handlers + probes). Kept as a documented variant in the build plan.
- **The Gitea built-in registry.** Would have made the portfolio the first
  in-cluster-registry consumer *and* required the in-cluster runner to build
  (it can't). GHCR is free, public, GitHub-native, and the cluster already pulls
  `ghcr.io` anonymously.
- **A token in the pod for the git feed.** Pointing at a private repo would put
  a credential on a public-facing pod (RCE → repo read). Anonymous read of a
  public repo removes the blast radius entirely.
- **A `cv.` subdomain.** Undersells a multi-page site and yields awkward paths
  (`cv.henrydowd.dev/about`). The apex is the front door.

## Consequences

- **Deploys depend on the Gitea→GitHub mirror + GitHub Actions.** If GitHub is
  down, no new builds (running pods are unaffected).
- **CD is fully wired (verified 2026-06-17).** The GitHub Actions secret
  `HOMELAB_TOKEN` (a Gitea PAT with write to `henry/homelab`) is set, so every
  build pins the new `ghcr.io/hpdowd/portfolio:<sha>` into
  `k8s/apps/portfolio/deployment.yaml` and ArgoCD rolls it out automatically —
  confirmed end-to-end. (Before the secret was set the deployment sat on
  `:latest`, and a deploy needed `kubectl -n portfolio rollout restart`.)
- **The GHCR package must stay public** (or the Deployment needs an
  `imagePullSecret`).
- **One more VM target + ~30–50Mi of worker RAM** for the portfolio pods.
  Negligible, but it counts against `NodeMemoryLowWorker` like everything else.

## Related

- docs/lessons/k8s/act-runner-no-docker-daemon.md — why the build moved to GitHub
- k8s/apps/monitoring/grafana-dashboard-portfolio.yaml + the `homelab.portfolio`
  rules in homelab-rules.yaml — the service's own Grafana dashboard + upstream alerts
- ADR 008 — Gitea Actions / GitHub for builds (this ADR extends it)
- k8s/apps/portfolio/ + k8s/apps/portfolio.yaml
- Source: git.henrydowd.dev/henry/portfolio (mirror: github.com/hpdowd/portfolio)
