# Incident: homepage crashloop — read-only /app/config vs. lazy skeleton seed

## Date
2026-07-23

## Time lost
~15min from the report to a fix rolling out; the app self-recovered between
crashes so the dashboard was only intermittently down.

## Status
Resolved

## Context
- **System / component:** `homepage` Deployment (gethomepage v1.13.2),
  `homepage` namespace, single replica pinned to `k3s-worker1`.
- **Scope:** homepage only, public dashboard. Links-only, no widgets.
- **State before:** freshly deployed and verified healthy — the pod came up
  Ready and served 200 on all hosts twice (initial deploy, then the
  `home.dowd.ie` roll). The crash started only *after* some interactive use
  ("a color change and a few page reloads").

## Symptoms
- Pod flapping: `RESTARTS` climbing (4–5), `BackOff`, `Readiness probe failed:
  connection refused` — but often `Running 1/1` when you looked, because it
  recovered between crashes. Intermittent, not a clean hard-down.
- Exit code 1, ~5s container lifetime per crash.
- `kubectl logs --previous`:
  ```
  error: ❌ Failed to initialize required config: /app/config/proxmox.yaml
  Reason: EROFS: read-only file system, copyfile
    '/app/src/skeleton/proxmox.yaml' -> '/app/config/proxmox.yaml'
  Hint: Make /app/config writable or manually place the config file.
  ```

## Investigation
- Original design mounted the config ConfigMap **read-only over the whole
  `/app/config` directory**, and tried to pre-empt homepage's default-file
  creation by shipping every file it "looks for" as a ConfigMap key
  (settings/services/bookmarks/widgets + empty docker/kubernetes/custom.*).
- That enumeration was **incomplete**: `ls /app/src/skeleton/` in the image
  showed **9** files, and the one missing from the ConfigMap was exactly
  `proxmox.yaml`.
- The subtlety that made it look intermittent: homepage does **not** seed the
  whole skeleton set at startup. The `proxmox.yaml` copy is **lazy** — it fires
  on some later code path (a config re-read / a page interaction), not on first
  boot. That's why the pod booted clean twice and only crashed once the trigger
  was hit. On a read-only mount the copy hits `EROFS` and the process exits 1.

## Root cause
Homepage v1.x creates skeleton/provider config files by **copying them into
`/app/config` at runtime** (a write), and does so lazily — not all at startup.
Mounting a ConfigMap read-only over `/app/config` makes any such write fail
`EROFS`. Trying to prevent the write by hand-listing every file homepage might
create is fragile: the required set is larger than documented and can grow on
any version bump. The write path, not the file list, was the real problem.

## Fix
Make `/app/config` **writable** and stop trying to enumerate homepage's files:

- `/app/config` is now an `emptyDir`, seeded by an **initContainer**
  (`busybox`, `cp -L /defaults/*.yaml /app/config/`) that copies in only the
  files we author (settings/services/bookmarks/widgets). Homepage then creates
  the rest of its skeleton set (proxmox/docker/kubernetes.yaml, custom.*, and
  `logs/`) into the writable dir itself, whenever it wants to.
- ConfigMap slimmed to just those 4 authored files; the empty
  docker/kubernetes/custom.* placeholders were deleted.
- `readOnlyRootFilesystem: true` is retained — only `/app/config` and
  `/app/.next/cache` are writable emptyDirs. Commit `78ccf8e`.

## Verification
```
kubectl -n homepage exec deploy/homepage -c homepage -- ls -1 /app/config
# bookmarks.yaml kubernetes.yaml logs services.yaml settings.yaml widgets.yaml
```
`kubernetes.yaml` and `logs/` are **not** in the ConfigMap — homepage created
them at runtime, which proves the write path is open. New pod Ready in ~10s, 0
restarts, and stayed at 0 after hammering the page + `/api/healthcheck`.

## Prevention
- **When an app copies/creates files into its config dir at runtime, give it a
  writable dir seeded by an initContainer — do not mount a ConfigMap read-only
  over that dir and try to pre-list every file.** The list is the app's to
  know, not yours, and it drifts across versions.
- A read-only ConfigMap mount is only safe over a dir the app *only reads*.
- Trade-off accepted: init-copy means config is not live — a ConfigMap edit
  needs `kubectl -n homepage rollout restart deploy/homepage`. That was already
  true here (homepage's file watcher lags the k8s remount anyway).

## Related
- Manifests: k8s/apps/homepage/deployment.yaml, configmap.yaml
- Plan: docs/plans/phase-9-homepage.md
