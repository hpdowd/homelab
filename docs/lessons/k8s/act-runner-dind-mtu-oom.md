# Incident: Gitea act_runner bring-up — DinD MTU black-hole + Go-GC OOM

## Date
2026-06-13

## Time lost
~1.5h (bring-up debugging; no user-facing outage — Actions was new)

## Status
Resolved

## Context
- **System / component:** `act-runner` Deployment in the `gitea` namespace
  (act_runner agent + privileged `docker:dind` sidecar), k3s-worker1.
- **Scope:** Gitea Actions only — a new feature being stood up (ADR 008).
  No existing service affected.
- **State before:** Fresh deployment. Goal: manifest CI (kubeconform over
  `k8s/**`) running on every push.

## Symptoms
Three distinct failures, in order:

1. **Pod CrashLooping on startup**, `runner` container exit 137:
   ```text
   runner ... terminated reason=OOMKilled exitCode=137  (limit 192Mi)
   ```
2. After raising to 384Mi the pod ran, **but the CI job failed** at the
   "install kubeconform" step — and only after a long hang:
   ```text
   curl: (35) OpenSSL SSL_connect: Connection reset by peer in connection to github.com:443
   gzip: stdin: unexpected end of file
   tar: Child returned status 1
   🏁  Job failed
   ```
   The `actions/checkout@v4` step *succeeded* (it clones from the internal
   Gitea service); only steps reaching the public internet failed, ~2.5min
   after starting.
3. After the MTU fix, a job would **succeed but the runner still OOMKilled
   mid-run** at 384Mi (exit 137), restart, and re-register. Idle RSS was
   ~10Mi — the spike was during job execution.

## Investigation
- **OOM #1 (192Mi):** assumed a startup spike, bumped to 384Mi. Wrong
  assumption that it was startup-only — see OOM #2.
- **curl reset to github:** ruled out DNS (checkout resolved/cloned fine;
  act_runner itself fetched the `checkout` action from github). Ruled out
  a real github outage (reproduced locally — kubeconform downloaded and
  validated the repo cleanly: `Valid: 59, Invalid: 0`). So the *manifests
  and the command were fine* — the failure was environmental, inside the
  job container, only on internet-bound TLS. The ~2.5min hang-then-reset
  is the signature of large packets being silently dropped (PMTU
  black-hole), not a refused connection.
  - Confirmed: pod `eth0` (flannel VXLAN) is **MTU 1450**; dind's `docker0`
    and the per-job bridge networks were **MTU 1500**. Job containers
    emitted 1500-byte DF frames out a 1450 path → TLS ServerHello dropped
    → eventual reset. Local Gitea traffic stayed small, so checkout worked.
- **OOM #2 (384Mi, mid-job):** the act_runner agent is a Go binary. Go's
  GC grows the heap toward the cgroup limit and doesn't know the cgroup
  cap unless told — so it over-allocated under job load and got
  OOMKilled despite a ~10Mi idle working set.

## Root cause
Two independent bring-up defects:
1. **MTU:** Docker bridges default to 1500; the k3s pod network is 1450.
   act_runner-created job networks inherited 1500, black-holing internet
   TLS from inside jobs.
2. **Go GC vs cgroup:** no `GOMEMLIMIT`, so the runtime's greedy heap
   growth tripped the container memory limit under load.

## Fix
Both declarative, in `k8s/apps/gitea/`:

- **MTU** — `daemon.json` (in the act-runner ConfigMap, mounted at
  `/etc/docker/daemon.json` in the dind sidecar), pins every bridge,
  including act_runner's per-job networks (`default-network-opts`, needs
  docker ≥ 26 — we run docker:27-dind):
  ```json
  {
    "mtu": 1450,
    "default-network-opts": { "bridge": { "com.docker.network.driver.mtu": "1450" } }
  }
  ```
  Commit `5b08df3` (`fix(gitea): pin dind bridge mtu to 1450 ...`).
- **OOM** — runner mem limit 192→384→**768Mi** plus a soft
  `GOMEMLIMIT=700MiB` so Go GCs before the hard cap. Commits the mem-bump
  and `5de40c0` (`... 384Mi->768Mi + GOMEMLIMIT ...`).

## Verification
```bash
# bridge MTU now 1450 on the per-job networks
kubectl -n gitea exec deploy/act-runner -c dind -- \
  docker network inspect bridge -f '{{index .Options "com.docker.network.driver.mtu"}}'   # -> 1450

# a dispatched run completes green, kubeconform actually ran:
#   Summary: 101 resources found in 84 files - Valid: 59, Invalid: 0, Errors: 0, Skipped: 42
#   🏁  Job succeeded
# (run #9, workflow_dispatch — confirmed in the action log)
```

## Prevention
- Documented as two gotchas (`docs/reference/gotchas.md` → Gitea Actions /
  DinD). The MTU one generalises: **any** privileged-docker workload on
  this flannel cluster must match the inner bridge to the 1450 pod MTU.
- `GOMEMLIMIT` is now the default reflex for any Go workload given a tight
  cgroup limit here.
- Reproduce-locally-first paid off: running the exact CI command on the
  workstation isolated "plumbing vs manifests" in one step.

## Related
- ADR: docs/adr/008-gitea-actions.md
- Gotchas: docs/reference/gotchas.md (Gitea Actions / DinD)
- Manifests: k8s/apps/gitea/act-runner*.yaml
