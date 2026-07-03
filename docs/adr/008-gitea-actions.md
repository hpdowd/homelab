# ADR 008: Gitea Actions, in-cluster runner for manifest CI, GitHub for heavy builds

**Status:** Accepted — runner execution model superseded by ADR 010
**Date:** 2026-06-13
**Superseded By:** ADR 010 (runner model only: DinD → host executor; the
in-cluster manifest CI and GitHub-for-heavy-builds decisions still stand)

## What problem this solves

The repo in Gitea (`henry/homelab`) is the source ArgoCD syncs with
`selfHeal`; a malformed manifest that merges is applied to the live
cluster within seconds, no human gate. There was no CI to catch a broken
`kustomize`/kubeconform-invalid manifest before it reached the cluster.
Separately, app repos hosted in Gitea (e.g. NextKeep, an Android/Kotlin
app) had no build automation at all.

Gitea ships GitHub-Actions-compatible CI, but the server only schedules
and stores; jobs run on a separate `act_runner` process that must be
deployed and registered. So "enable Actions" is really two decisions:
**where the runner lives** and **what it's allowed to run**.

## What I picked

1. **One in-cluster `act_runner`, Docker backend with a DinD sidecar**,
   in the `gitea` namespace, pinned to `k3s-worker1`. The runner agent is
   tiny (~10Mi idle); the privileged `docker:dind` sidecar hosts the
   per-job containers. This is the standard, GitHub-faithful execution
   model, fresh container per job.
2. **Sized deliberately small for manifest CI, not builds.** capacity 1,
   runner mem limit 768Mi, dind 1Gi, DinD image storage on a 15Gi
   Longhorn PVC (on tank/vdb, *not* the worker's already-pressured vda
   root). It validates `k8s/**` with kubeconform on every push, seconds
   long, sub-512Mi jobs.
3. **Heavy builds go to GitHub-hosted runners, not this cluster.** The
   NextKeep Android build wants ~4GiB+ RAM (Gradle + Kotlin + AGP
   daemons, spiking). The worker is 14GiB total, gates everything on
   13.59GiB, and `NodeMemoryLowWorker` already fires at <2GiB free, there
   is no room for a 4GiB transient without risking OOM on Immich/Nextcloud.
   NextKeep builds on GitHub's free 7GiB/2vCPU runners (push-mirror Gitea →
   GitHub if the source of truth stays in the homelab).
4. **Registration token as a SealedSecret** (`gitea-act-runner`), same
   posture as every other secret here; instance-level, reusable.

## What I rejected

- **Host execution backend** (`act_runner` runs steps directly in the
  runner pod, no privileged container), avoids the one privileged
  container in the stack, but jobs share and pollute the runner's
  filesystem with no isolation. For a GitOps repo whose CI guards the
  live cluster, container-per-job isolation is worth the privileged dind.
- **Building NextKeep (Android) on the cluster.** The decisive numbers
  are above, 4GiB+ on a node with ~2GiB headroom. Not logical for sparse
  use even with storage on tank; GitHub's runners are free, larger, and
  carry zero homelab footprint.
- **`kustomize build` as the CI check:** the ArgoCD app uses *directory*
  mode (no `kustomization.yaml`), so there's nothing repo-wide to
  `kustomize build`. kubeconform over the raw YAML is the right validator;
  `-ignore-missing-schemas` skips the CRDs we don't vendor (Application,
  SealedSecret, VMRule) while still catching core-kind errors.
- **GitHub for *everything* (mirror the homelab repo, drop Gitea Actions)**,
  manifest CI belongs next to the GitOps source, runs in seconds, and
  keeps the cluster-guarding loop self-contained. Only the heavy,
  bursty workloads are offloaded.

## Consequences

- The privileged dind sidecar is now the one near-root container in the
  cluster, confined to the worker, running only Henry's own workflows.
  Accepted risk for a single-user homelab; revisit if multi-tenant.
- Two bring-up gotchas, both non-obvious, now documented (see Related):
  the DinD bridge MTU black-hole (job egress to the internet silently
  reset) and the act_runner Go-GC OOM against a low cgroup cap.
- DinD image layers accumulate on the 15Gi PVC, `docker system prune`
  periodically if it fills. The catthehacker job image (~1–2GiB) is
  cached there after the first run.
- Added footprint when idle is ~384Mi reserved (requests), bursting to
  ~1.77Gi during a job, small against the worker, but it's one more
  tenant on the node that gates Immich. Watch `NodeMemoryLowWorker` if
  CI and a big Immich import ever overlap.
- Rebuild path: everything is in git (manifests, sealed token, workflow)
  except the sealed-secrets master key dependency shared by all secrets.
  The runner re-registers from the token on a fresh pod.

## Related

- docs/lessons/k8s/act-runner-dind-mtu-oom.md, the bring-up post-mortem
  (MTU reset + Go-GC OOM, with the dead ends)
- docs/reference/gotchas.md, the two sharp edges, indexed
- ADR 005 / docs/reference/capacity-headroom.md, the worker RAM ceiling
  that rules out Android-on-cluster
