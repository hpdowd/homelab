# ADR 010: act_runner on the host executor — drop the privileged DinD sidecar

**Status:** Accepted
**Date:** 2026-07-03
**Supersedes:** ADR 008, runner execution model only (the rest of 008 stands)

## What problem this solves

ADR 008 stood up Gitea Actions with a Docker-in-Docker sidecar so every
job runs in a fresh container — the GitHub-faithful model. The cost, named
in 008's own Consequences, is that the `docker:dind` sidecar is the one
privileged, near-root container in the cluster.

Re-examining the trade: this runner has exactly one workflow, and it only
validates `k8s/**` with kubeconform. It builds no images and needs no
Docker daemon — the daemon existed solely to spawn the per-job container.
So the container-per-job isolation that justified the privileged sidecar in
008 buys almost nothing here, while the privileged daemon stays the single
largest attack-surface item in the cluster. For a daemonless lint job that
balance no longer holds.

## What I picked

**The `act_runner` host executor.** `:host` labels run the job's steps
directly in the runner container instead of spawning a container through a
daemon. Concretely:

1. **Deleted the privileged `docker:dind` sidecar** and everything that
   only served it — the shared TLS `certs` volume, the `DOCKER_HOST`/cert
   env, the 15Gi `act-runner-dind` PVC (image-layer store; no layers now),
   and the `daemon.json` (the MTU-1450 bridge fix, moot with no docker
   bridge). The runner is now a single unprivileged container.
2. **Rewrote the workflow to the tools baked into the `act_runner` image**
   (git, wget+ssl_client, tar, sha256sum). Host jobs run *in* that image,
   which has no node and no curl — so `actions/checkout` (a Node.js action)
   became a hand-rolled anonymous `git clone` of the in-cluster Gitea
   Service, and the kubeconform download moved to `wget` and is now pinned
   by sha256 + `sha256sum -c`.
3. **A one-time, idempotent startup guard** drops the persisted
   `/data/.runner` if it still carries the old `docker://` label mapping,
   so the runner re-registers with host labels (the token is reusable). It
   no-ops once migrated.

Net: one fewer container, one fewer PVC, two fewer volumes — and the
cluster's only CI-executing privileged container is gone.

## What I rejected

- **Keeping DinD (008's choice).** Defensible when a runner builds images
  or runs untrusted, multi-tenant CI; neither is true here. Paying for a
  privileged daemon to lint YAML is the wrong side of the trade.
- **Rootless DinD / Sysbox / gVisor.** All keep or replace the daemon and
  add either kernel/feature caveats or a node-level runtime to install and
  maintain. Disproportionate when the job needs no daemon at all — they
  make the privileged thing *safer* rather than *removing* it.
- **A custom runner image bundling node** (to keep `actions/checkout`).
  Trades the daemon for an image to build and track; the hand-rolled clone
  removes the dependency outright and drops a mutable action tag from the
  supply chain as a bonus.

## Consequences

- **No container-per-job isolation.** Job steps share the runner
  container's filesystem, cleaned between runs by the runner rather than by
  container teardown. Accepted: single-user repo, registration disabled
  (`DISABLE_REGISTRATION`), only Henry's own manifest CI runs here. Revisit
  if this ever runs untrusted or multi-tenant workflows — that is the
  condition that swings the trade back toward isolation.
- **The workflow is constrained to the image's tools** — no Node.js
  actions, no `docker build`. A future job needing either wants a different
  runner (custom image, or offload to GitHub-hosted like the Android build
  already is).
- **Two of the three DinD gotchas retire.** The bridge-MTU black-hole and
  the "dind gives the runner a daemon, not the job" trap no longer apply;
  the Go-GC `GOMEMLIMIT` one still does (act_runner is still a Go binary).
  `gotchas.md` is annotated.
- **Supply chain tightened as a side effect:** checkout is a pinned git
  clone (no mutable `@v4`), kubeconform is checksum-verified.
- **`ServiceAccount` token no longer mounted.** With job shell running in
  the runner container, `automountServiceAccountToken: false` keeps the
  namespace default token out of the job's reach; act_runner talks to
  Gitea, never the Kubernetes API, so nothing needs it.
- **Rebuild path unchanged:** the sealed token re-registers on a fresh pod,
  now with host labels via the guard.

## Related

- ADR 008 — the DinD decision this supersedes (runner model only)
- docs/lessons/k8s/act-runner-dind-mtu-oom.md — the DinD bring-up
  post-mortem; historical now, kept for the MTU / Go-GC reasoning
- docs/reference/gotchas.md — Gitea Actions / DinD section, annotated
