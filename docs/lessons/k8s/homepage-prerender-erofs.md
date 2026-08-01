# Finding: homepage served the demo page for 9 days — read-only Next.js prerender

## Date
2026-08-01

## Time lost
~20min, all of it in diagnosis. Zero downtime: the pod was Ready and 200ing
the whole time, it was just serving the wrong page.

## Status
Resolved

## Context
- **System / component:** `homepage` Deployment (gethomepage v1.13.2),
  `homepage` namespace, public dashboard on `dash.lan` /
  `dash.henrydowd.dev` / `home.dowd.ie`.
- **Scope:** the dashboard's own rendering. No other service affected.
- **State before:** deployed 2026-07-23 and "verified" with
  `curl -o /dev/null -w '%{http_code}'` — which is exactly why this survived
  nine days. Status code 200, pod Ready, ArgoCD Synced/Healthy.

## Symptoms
`curl https://home.dowd.ie/` returned the image's built-in demo page —
`My First Group` / `My First Service` / "Homepage is awesome", `<title>` of
`Homepage` — on every hostname, while `/app/config/settings.yaml` in the pod
held the real config and `/api/services` returned the real services.

In a browser it mostly looked fine, which is why nobody noticed: the service
and bookmark lists are re-fetched client-side and overwrite the demo content
on hydration. What stayed wrong was everything that comes from
`settings.yaml` at render time — page title, `headerStyle`, `layout`, group
order, theme colour.

## Investigation
- Config on disk was correct (`kubectl exec -- ls -la /app/config`), and
  `wget -O- http://127.0.0.1:3000/` from inside the container returned the
  demo page — so this was not Traefik, the tunnel, or a stale cache anywhere
  in the request path. The app itself was serving it.
- `/app/config/logs/homepage.log` had one warning from first boot, never
  repeated:
  ```
  warn: Failed to update prerender cache for /en
  Error: EROFS: read-only file system,
    open '/app/.next/server/pages/en.html'
  ```
- `grep -c "My First Service" /app/.next/server/pages/en.html` → 1. The file
  is dated Jun 9 — the image build date. That was the page being served.

## Root cause
Homepage is a Next.js app that ships a **prerendered** `en.html` baked at
image build time (against the skeleton config, hence the demo content) and
regenerates it at runtime via `/api/revalidate`, which **writes**
`/app/.next/server/pages/en.html`.

`readOnlyRootFilesystem: true` (ADR 011) made that write fail `EROFS`. The
2026-07-23 fix gave homepage a writable `/app/config` and `/app/.next/cache`
— but not `/app/.next/server/pages`, where the rendered page actually lands.
So the regeneration failed silently, forever, and the build-time demo page
was served on every request.

The failure mode is nastier than the July crashloop: nothing restarts,
nothing alerts, the endpoint returns 200, and client-side hydration patches
over the most visible half of the damage.

## Fix
Give the prerender directory the same treatment as `/app/config` — writable
`emptyDir`, seeded from the image by an initContainer (which must use the
homepage image; that's where the built pages live):

```yaml
initContainers:
  - name: seed-prerender
    image: ghcr.io/gethomepage/homepage:v1.13.2
    command: ["sh", "-c", "cp -r /app/.next/server/pages/. /seed/"]
    volumeMounts: [{ name: prerender, mountPath: /seed }]
# container:
    volumeMounts:
      - { name: prerender, mountPath: /app/.next/server/pages }
```

Plus a **startup probe on `/api/revalidate`**, so the real config is burned
into the page before the pod ever goes Ready:

```yaml
startupProbe:
  httpGet: { path: /api/revalidate, port: http }
  periodSeconds: 5
  failureThreshold: 24
```

Kubernetes suppresses readiness and liveness until the startup probe passes,
and stops probing after the first success — so it regenerates exactly once,
at startup, and no visitor is ever served the seeded demo page.
`readOnlyRootFilesystem: true` is retained.

## Verification
Reproduced and fixed locally before touching the cluster, with the container
run `--read-only --user 1000:1000` and only those three paths writable:
first request served the demo page, `/api/revalidate` returned
`{"revalidated":true}` (it had been failing EROFS), and the next request
served `Dowd Homelab` + the real services. No EROFS in the logs.

## Prevention
- **`%{http_code}` is not a smoke test for a page.** A dashboard that 200s
  can still be serving another site's content. Grep the response for a string
  only *your* config produces — the title, a service name — the way
  `services.md` smoke tests do for other apps.
- **`readOnlyRootFilesystem` needs the app's full write set, not the obvious
  one.** For a Next.js app that's `.next/cache` *and* `.next/server/pages`.
  Grep the app's own log file for `EROFS` after the first deploy, not just
  `kubectl logs` — homepage writes its warnings to
  `/app/config/logs/homepage.log`, where nothing was looking.
- A one-shot `startupProbe` is a clean way to run a "warm this up before you
  take traffic" call without a `postStart` hook or a sidecar.

## Related
- Manifests: k8s/apps/homepage/deployment.yaml
- Sibling lesson (same app, same flag, different directory):
  docs/lessons/k8s/homepage-readonly-config-erofs.md
- Plan: docs/plans/phase-9-homepage.md
