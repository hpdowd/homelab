# Homepage (dashboard)

Current state of the household dashboard, as deployed. The walkthrough and the
decisions behind it are in `docs/plans/phase-9-homepage.md`; the two incidents
are in `docs/lessons/k8s/`. This file is what exists.

`ghcr.io/gethomepage/homepage:v1.13.2`, namespace `homepage`, one replica on
`k3s-worker1`. Last verified 2026-09-03.

## Role

One stateless Next.js container that renders a link grid from a ConfigMap.
No database, no PVC, no secrets. A pod loss re-renders the page from git.

It is a launcher, not a monitor. The live-data widgets that would make it a
monitor are **not deployed** — see "Not implemented".

## Hostnames

| Host | Auth | Served by |
|---|---|---|
| `dash.henrydowd.dev` | **Authelia ForwardAuth, `one_factor`** | Ingress `homepage` |
| `dash.lan` | none — trusted network, break-glass | Ingress `homepage-ungated` |

Two objects, not one, because the ForwardAuth annotation attaches to the Ingress
**object**. `dash.lan` is bare deliberately: it is outside the `henrydowd.dev`
cookie domain, so ForwardAuth on it would redirect-loop, and it is the way in
when Authelia is down.

Both ride the `*.henrydowd.dev` wildcard for cert, DNS and tunnel, so neither
carries a `tls:` block (ADR 007).

**`home.dowd.ie` was removed on 2026-09-03.** It served this same pod on a
second Cloudflare zone. A second apex cannot share the `henrydowd.dev` session
cookie, so it could not be ForwardAuth'd without giving Authelia a whole second
cookie domain — and while it existed, gating `dash.henrydowd.dev` did nothing
for the page's privacy. Dropping it is what actually made the dashboard
private. Its Ingress rule, `tls:` block, `*.dowd.ie` Certificate and
`HOMEPAGE_ALLOWED_HOSTS` entry went with it; the orphaned `dowd-ie-tls` Secret
was deleted by hand, because ArgoCD prunes the Certificate but not the Secret
cert-manager creates from it.

Still outside this repo and **not** removed: the cloudflared public-hostname
route and the Technitium `home.dowd.ie → 192.168.1.200` record. Until those go
the name resolves and Traefik answers 404.

## Kubernetes objects

All in `k8s/apps/homepage/`, synced by the `homepage` ArgoCD Application with
`prune: true, selfHeal: true`.

| File | Object | Notes |
|---|---|---|
| `namespace.yaml` | Namespace | Explicit per ADR 014 |
| `deployment.yaml` | Deployment | 1 replica, `RollingUpdate` (no PVC), worker-pinned, **two initContainers** |
| `configmap.yaml` | ConfigMap `homepage` | 5 files; the source the initContainer copies from |
| `service.yaml` | Service | `:3000` → named port `http` |
| `ingress.yaml` | 2 × Ingress | `homepage` (gated) + `homepage-ungated` |
| `networkpolicy.yaml` | NetworkPolicy | Default-deny ingress, 3000 only |

## The two EROFS traps

This deployment is shaped almost entirely by `readOnlyRootFilesystem: true`
colliding with an app that writes into its own image. Both traps cost an
incident. **Three emptyDirs and two initContainers exist because of them — none
is incidental.**

**1. `/app/config` (`homepage-readonly-config-erofs.md`).** Homepage copies its
own skeleton files (`proxmox.yaml`, `docker.yaml`, `kubernetes.yaml`,
`custom.js`) into `/app/config` at startup. Mount the ConfigMap there directly
and that copy fails EROFS and the pod crashes. So the ConfigMap is mounted at
`/defaults` as `config-src`, an initContainer copies it into an emptyDir, and
homepage fills in the rest itself.

The copy is `cp -L /defaults/*` — a glob, not `*.yaml`, because the ConfigMap
also carries `custom.css`. The ConfigMap volume's own `..data` symlink
directories start with a dot, so the glob skips them.

**2. `/app/.next/server/pages` (`homepage-prerender-erofs.md`).** The nastier
one, because nothing crashes. Homepage serves a **prerendered page built into
the image** — the "My First Service" demo — and regenerates it via
`/api/revalidate`, writing `en.html`. Under a read-only rootfs that write fails
silently, so the dashboard is frozen on the demo content forever. Only the
service and bookmark lists self-correct, because those are re-fetched
client-side; the title, header style and layout do not.

Fixed with a second emptyDir seeded by a second initContainer, which must use
the **homepage image itself** — that is where the built pages live. It copies
with `cp -r`, not `cp -a`: it runs as uid 1000 into a root-owned emptyDir, and
`-a`'s chown attempts only print noise.

The third emptyDir, `/app/.next/cache`, is ordinary Next.js render scratch.

## Configuration

Five files in the ConfigMap, all non-secret, all in plain git.

| File | Contents |
|---|---|
| `settings.yaml` | Title, dark/slate theme, `headerStyle: clean`, group layout and order |
| `services.yaml` | The link grid — **static, hand-listed** |
| `bookmarks.yaml` | Three reference links (k8s, ArgoCD, homepage docs) |
| `widgets.yaml` | Header only: `greeting`, `datetime`, `search` |
| `custom.css` | The masthead treatment; group headings are CSS, not icons |

Three service groups, twelve entries: **Media** (Immich, Nextcloud, Collabora),
**Tools** (Paperless, Gitea, Kiwix, AMP), **Infrastructure** (Proxmox, ArgoCD,
Grafana, Technitium).

Discovery is deliberately static rather than Kubernetes ingress auto-discovery:
twelve services are trivial to hand-list, and auto-discovery needs a
cluster-wide RBAC read on ingresses plus the risk of surfacing something not
meant to be published.

`widgets.yaml` carries no `resources` widget (CPU/mem/disk) and no weather
widget. The first was held back while the page was public; the second would
publish the house's coordinates.

## `HOMEPAGE_ALLOWED_HOSTS`

```
$(MY_POD_IP):3000,dash.lan,dash.henrydowd.dev
```

Load-bearing, and the single most likely bring-up failure. Any request whose
`Host` is not in this list gets `400 Bad Request: host validation failed`.

The pod-IP entry is not optional: the kubelet probe hits the **pod IP**, not a
hostname, so without it the pod never goes Ready. `MY_POD_IP` is declared
before it in the env list because Kubernetes only expands variables defined
earlier.

Adding or removing a hostname means editing this too. It is the step most
easily forgotten — it was updated when `home.dowd.ie` was removed.

## Probes

| Probe | Path | Why |
|---|---|---|
| startup | `/api/revalidate` | Burns the real config into the prerendered page **before** the pod goes Ready |
| readiness | `/api/healthcheck` | |
| liveness | `/api/healthcheck` | |

The startup probe is doing real work, not just waiting. Kubernetes holds off
readiness and liveness until it passes and stops probing after the first
success, so this regenerates the page exactly once per start. Without it, the
first visitor after every restart is served the image's demo page until their
browser happens to trigger a revalidate.

Note the endpoint: `/api/healthcheck`, not `GET /`. That changed from the older
0.9.x behaviour, which is part of why the tag is pinned.

## Security posture

Runs as uid 1000, `runAsNonRoot`, `seccompProfile: RuntimeDefault`, all
capabilities dropped, `readOnlyRootFilesystem: true` — the locked-down tier of
ADR 011. Both initContainers carry the same profile.

No secrets are mounted, and there is nothing to leak: every value in the
ConfigMap is a hostname or a CSS rule. That changes the moment step 4 lands.

NetworkPolicy is default-deny **ingress**, allowing 3000 from the pod CIDR and
both node IPs (kubelet probes come from the node, not a pod). **Egress is left
open deliberately** — widgets will need to reach service APIs cluster-wide, and
a restrictive egress policy here would risk the kube-router fresh-pod race that
broke nextcloud-cron.

## Current measurements

| | |
|---|---|
| Memory | ~99Mi resident (request 64Mi, limit 256Mi) |
| CPU | ~1m idle (request 50m) |
| Restarts | 0 |
| Storage | none — 3 emptyDirs, no PVC |

## Operations

**A ConfigMap edit does not hot-reload.** The initContainer only copies at pod
start, so a config change needs:

```bash
kubectl -n homepage rollout restart deploy/homepage
```

Check what the page is actually serving, rather than what the ConfigMap says:

```bash
curl -s -H 'Host: dash.lan' http://192.168.1.200/ | grep -o '<title[^>]*>[^<]*'
```

Expect `<title data-next-head="">Dowd Homelab`. The `[^>]*` is required — this is
Next.js, and it emits `<title data-next-head="">`, so a literal `<title>` never
matches and the command silently returns nothing.

A blunter check for the same thing:

```bash
curl -s -H 'Host: dash.lan' http://192.168.1.200/ | grep -c 'My First Service'
```

`0` is healthy. Anything above `0` means the page is serving the image's built-in
demo, so the prerender seeding is broken — that is the second EROFS trap, and it
is a config-independent failure: the ConfigMap can be perfect and the page still
wrong.

Test the gated path from off-network, since split-horizon DNS hides Authelia
from the LAN:

```bash
ip=$(dig +short dash.henrydowd.dev @1.1.1.1 | grep -E '^[0-9]' | head -1)
curl -s -o /dev/null -w '%{http_code} %{redirect_url}\n' \
  --resolve dash.henrydowd.dev:443:$ip https://dash.henrydowd.dev/
```

Expect `302` to `auth.henrydowd.dev`. A `200` means the gate is off.

Nothing to back up. The config is in git and the pod is stateless.

## Known constraints

- `HOMEPAGE_ALLOWED_HOSTS` must list every hostname **and** the pod IP, or that
  request 400s.
- A ConfigMap edit needs a `rollout restart`.
- A YAML typo in `services.yaml` renders an error card but leaves the pod up —
  check the container logs, not the pod status.
- The image tag is pinned because both the config schema and the
  `HOMEPAGE_ALLOWED_HOSTS` behaviour drift between releases. Re-read the pinned
  tag's docs before bumping.
- Both EROFS traps are invisible in `kubectl get pods`: the first crashes with
  an unhelpful error, the second does not fail at all.

## Not implemented

**Phase 9 step 4: the keyed live-data widgets** — Grafana, Immich and Proxmox
polling their APIs with stored keys, plus the `resources` widget, plus an
API-key SealedSecret.

This was blocked from July until 2026-09-03, not by the work but by the
precondition: keyed widgets render live infrastructure data into the page, so
every hostname serving this pod has to require auth first. Gating
`dash.henrydowd.dev` alone did not achieve that while `home.dowd.ie` answered
the same pod ungated.

**That precondition now holds.** `dash.henrydowd.dev` is gated and `dash.lan` is
trusted-network only, so step 4 is safe to do. It has not been done.

The general form is worth keeping: **a gate belongs to a hostname, not to a
service, and a pod is only as private as its most open name.**
