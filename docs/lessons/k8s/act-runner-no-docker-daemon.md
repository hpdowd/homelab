# Incident: act_runner jobs can't reach the dind daemon — `docker build` fails

## Date
2026-06-17

## Time lost
~1h (debugging; no user-facing outage — the portfolio wasn't live yet)

## Status
Resolved (image build moved to GitHub-hosted runners)

## Context
- **System / component:** the `act-runner` Deployment in `gitea` (agent +
  privileged `docker:dind` sidecar) from ADR 008.
- **Scope:** the first workflow that tried to `docker build` an image — the
  portfolio. Every prior job had been kubeconform (no Docker).
- **State before:** portfolio CI added as `.gitea/workflows/build.yaml` to build
  the image, push it to the Gitea registry, and bump the homelab tag.

## Symptoms
The job failed. Registry login *succeeded*, then the build step died:
```text
Login Succeeded
ERROR: failed to connect to the docker API at unix:///var/run/docker.sock; ...
       dial unix /var/run/docker.sock: connect: no such file or directory
Job 'build' failed
```
The pod sat in `ImagePullBackOff` on the image that was never pushed.

## Investigation
**Including the dead ends — they were most of the time:**
- **"It's memory"** (first instinct, matching the NextKeep pattern) → wrong: the
  portfolio image is tiny; this never reached a resource limit.
- **"It's the Dockerfile"** → reproduced the build locally with `podman build`:
  clean, exit 0, all three stages. So the Dockerfile and image were fine.
- **"Private package / bad token"** → the log says `Login Succeeded`; the failure
  is *after* login, at `docker build`. Not auth.
- Pulled the actual stored job log (zstd under
  `/data/gitea/actions_log/henry/portfolio/14/20.log.zst`) → the `docker.sock`
  error above, which is the smoking gun.

## Root cause
act_runner runs each job step inside a job container (`catthehacker/ubuntu`)
spawned on the dind daemon. **That job container has no Docker daemon of its
own:** no `/var/run/docker.sock`, and `DOCKER_HOST` is not propagated into it
(the dind daemon is TLS-only on the *runner pod's* `localhost:2376`, with certs
in an `emptyDir` the job containers don't mount). The runner was only ever wired
for kubeconform jobs, which don't touch Docker, so docker-in-job was never set
up. `docker login` works because it only writes a config file and talks to the
registry over the network; `docker build`/`push` need the daemon and fail.

The dind sidecar gives **the runner** a Docker daemon (to spawn job containers),
**not the job steps**. That distinction is the trap.

## Fix
Move the image build off the in-cluster runner entirely, onto GitHub's free
hosted runners (which have a real Docker daemon) — per ADR 008's "builds that
don't fit the worker go to GitHub" principle; here it's not heaviness but the
missing daemon. The Gitea portfolio repo push-mirrors to GitHub;
`.github/workflows/build.yml` builds and pushes to GHCR. The in-cluster
`.gitea/workflows/build.yaml` was removed, and the new workflow's job is guarded:
```yaml
jobs:
  build:
    if: github.server_url == 'https://github.com'   # skipped on the Gitea mirror
```
so the in-cluster runner picks the workflow up (Gitea also reads
`.github/workflows/`) but skips it instead of re-failing.

*Alternative not taken:* wire docker-in-job on the shared runner — mount the dind
TLS certs + inject `DOCKER_HOST` into jobs, or switch dind to a non-TLS socket.
Rejected: fiddly, destabilises a runner shared with the cluster-guarding
kubeconform CI, and ADR 008 already sends builds to GitHub.

## Verification
```bash
# GitHub Actions run: build + push to ghcr.io/hpdowd/portfolio succeeded.
kubectl -n portfolio get pods          # portfolio-... 1/1 Running (pulled GHCR anonymously)
# recursive scrape live:
#   up{namespace="portfolio"} = 1   and   portfolio_build_info{commit="d499d93..."} present
```

## Prevention
- **The in-cluster act_runner is for daemonless jobs only** — kubeconform, lint,
  unit tests that don't build images. Any container-image build goes to
  GitHub-hosted runners via the push-mirror. Recorded in ADR 009.
- Sharper restatement of the NextKeep rule: *the dind sidecar gives the runner
  Docker, not the job.* Don't assume a job step can `docker build` just because a
  dind sidecar exists.
- Reproduce-locally-first paid off again (podman proved the image was fine in one
  step, redirecting the search from "the build" to "the runner").

## Related
- ADR: docs/adr/009-portfolio.md, docs/adr/008-gitea-actions.md
- Other lessons: docs/lessons/k8s/act-runner-dind-mtu-oom.md (the runner's
  bring-up gotchas)
