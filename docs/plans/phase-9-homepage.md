# Phase 9: Homepage (household dashboard) walkthrough

*Drafted 2026-07-22. Pin the exact `ghcr.io/gethomepage/homepage` release
before deploying — the config schema (widget keys, `settings.yaml` fields)
drifts between minors, and `HOMEPAGE_ALLOWED_HOSTS` behaviour changed in the
0.9.x line. Verify keys against the pinned version's docs.*

Execution order: this ships **before** revisiting Authelia (phase 8) per the
household-services roadmap; the phase number is just an identifier here (cf.
6c/6d landing after phase 7 in the status table), not a timeline.

> ## Status: SHIPPED and gated. Step 4 (widgets) is UNBLOCKED and not yet done.
> *Updated 2026-09-03.*
>
> Homepage is live on `ghcr.io/gethomepage/homepage:v1.13.2`, now serving
> exactly two hostnames: `dash.henrydowd.dev` (Authelia `one_factor`) and
> `dash.lan` (bare, break-glass).
>
> `home.dowd.ie` shipped as well — so the "alternative" section below describes
> work that was done, not a road not taken — and was **removed on 2026-09-03**.
> That removal is what actually satisfied step 4's precondition. Gating
> `dash.henrydowd.dev` alone had not: the same pod answered on `home.dowd.ie`,
> a second apex that cannot share the `henrydowd.dev` session cookie, so one
> ungated name kept the whole page world-readable. Dropping it was the cheapest
> of ADR 018's three options.
>
> **Step 4 can now proceed.** Config is still links-only — no `widget:` blocks
> with API keys, no SealedSecret; the header carries `greeting` and `datetime`
> only, and the `resources` widget is still out. Adding them is the remaining
> work, and it is now safe.

Architecture: [gethomepage/homepage](https://gethomepage.dev) — one stateless
container, all config in a ConfigMap, no database, no PVC. It renders a link
grid plus optional live widgets that poll each service's API (those need keys,
so a SealedSecret). ~40–80Mi resident. The one service on this cluster whose
entire job is to point at the others.

No ADR — a stateless dashboard with its config in git doesn't warrant one. The
decisions below live in this plan.

| Decision | Choice | Why |
|---|---|---|
| App | gethomepage/homepage | de-facto standard, single static container, YAML config, no DB/PVC |
| Config | ConfigMap in git (`settings/services/bookmarks.yaml`) + SealedSecret for widget API keys | config is non-secret; only the API keys are sealed |
| Discovery | **static `services.yaml`**, NOT k8s ingress auto-discovery | ~13 services is trivial to hand-list; auto-discovery needs a cluster-wide RBAC read on ingresses and risks surfacing something you didn't mean to publish |
| Storage | none (ConfigMap only; `emptyDir` for the Next.js cache) | nothing to persist |
| Hostname | `dash.lan` + `dash.henrydowd.dev` | `home.henrydowd.dev` is the WireGuard/SSH record (taken); `dash.*` rides the `*.henrydowd.dev` wildcard — **zero** DNS/cert/tunnel work. `home.dowd.ie` alternative costed at the bottom |
| Auth | **as built:** `dash.henrydowd.dev` ForwardAuth `one_factor`; `dash.lan` bare; `home.dowd.ie` removed 2026-09-03 | gating one name of two had left the page world-readable — see the status block |
| `HOMEPAGE_ALLOWED_HOSTS` | `dash.lan,dash.henrydowd.dev` | **load-bearing** since 0.9.x — unset (or wrong) ⇒ every proxied request 400s with `Bad Request: host validation failed` |

Preflight — DNS, cert, and tunnel need **zero work**: `dash.henrydowd.dev`
resolves the moment the Ingress exists (Technitium `*.henrydowd.dev` →
192.168.1.200 on LAN; cloudflared `*.henrydowd.dev` wildcard already tunnels
it publicly), and the LE wildcard TLSStore covers it on `websecure`. RAM is a
non-issue (~40–80Mi against the worker's NodeMemoryLowWorker <2GiB gate).

---

## Step 1: exposure decision — links now, widgets after gating

You chose **public from day one, Authelia later**. The links themselves are
not secrets (they're just hostnames already in DNS). The risk is *widgets*: a
Grafana/Immich/Proxmox widget polls that service's API with a stored key and
paints live infra data (photo counts, CPU load, container states) onto a page
anyone on the internet can open.

So stage it:

- **Now (ungated):** ship **links + bookmarks only**. No `widget:` blocks, no
  SealedSecret. Nothing sensitive is exposed — worst case someone learns you
  run Immich, which the DNS already tells them.
- **Phase 8 (once `dash.henrydowd.dev` is behind Authelia ForwardAuth):** add
  the widgets and the API-key SealedSecret (step 4).

**Revised 2026-09-03, twice in one day.** The wording above was too loose:
gating *a* name is not gating *the page*, and `home.dowd.ie` reached the same
pod ungated. The precondition is that **every** hostname serving this pod
requires auth, not just the `henrydowd.dev` one.

That now holds — `home.dowd.ie` was removed, leaving only the gated
`dash.henrydowd.dev` and the trusted-network `dash.lan`. Step 4 is unblocked.

---

## Step 2: manifests

`k8s/apps/homepage/` **plus** `k8s/apps/homepage.yaml` (root-app is
non-recursive — a bare subdir with no top-level `<name>.yaml` is silently
orphaned):

- `namespace.yaml`
- `configmap.yaml` — `settings.yaml`, `services.yaml`, `bookmarks.yaml`,
  `widgets.yaml` (info widgets: resources/search/greeting). Sketch below.
- `deployment.yaml` — single replica (stateless, so plain `RollingUpdate` is
  fine, no RWO/Recreate concern), pinned to worker like everything else,
  `requests: 64Mi/50m`, `limits: 256Mi`. Config ConfigMap mounted at
  `/app/config`. securityContext per ADR 011 (locked-down tier — no root
  needed, it just serves HTTP on a high port):

  ```yaml
  securityContext:            # pod
    runAsNonRoot: true
    runAsUser: 1000
    seccompProfile: { type: RuntimeDefault }
  # container
  securityContext:
    allowPrivilegeEscalation: false
    readOnlyRootFilesystem: true
    capabilities: { drop: ["ALL"] }
  ```

  `readOnlyRootFilesystem: true` needs a writable Next.js cache — mount an
  `emptyDir` at `/app/.next/cache`. Env: `HOMEPAGE_ALLOWED_HOSTS`,
  `TZ=Europe/Dublin`, `PORT=3000`. probes: `GET /` on 3000.
- `service.yaml` — port 3000.
- `ingress.yaml` — `dash.lan` + `dash.henrydowd.dev`, `ingressClassName:
  traefik`, **no** entrypoints annotation, **no** `tls:` block (ADR 007).
- `networkpolicy.yaml` — default-deny-ingress + allow Traefik/probes to 3000
  (copy `kiwix/networkpolicy.yaml` verbatim, swap the port). **Leave egress
  open** — when widgets arrive homepage must reach service APIs cluster-wide,
  and a restrictive egress netpol here would trip the kube-router fresh-pod
  race the way it broke nextcloud-cron. Ingress-only is the safe tier.

`configmap.yaml` sketch (`services.yaml`, links-only first pass):

```yaml
# settings.yaml
title: Dowd Homelab
theme: dark
headerStyle: clean
layout:
  Infrastructure: { style: row, columns: 4 }
  Media: { style: row, columns: 3 }
  Tools: { style: row, columns: 4 }

# services.yaml
- Infrastructure:
    - Proxmox:   { href: https://proxmox.henrydowd.dev, description: Hypervisor }
    - ArgoCD:    { href: http://argocd.lan, description: GitOps (LAN-only) }
    - Grafana:   { href: https://grafana.henrydowd.dev, description: Metrics }
    - Technitium:{ href: http://technitium.lan, description: DNS (LAN-only) }
- Media:
    - Immich:    { href: https://immich.henrydowd.dev, description: Photos }
    - Nextcloud: { href: https://nextcloud.henrydowd.dev, description: Files }
    - Collabora: { href: https://collabora.henrydowd.dev, description: Office }
- Tools:
    - Gitea:     { href: https://git.henrydowd.dev, description: Git }
    - Kiwix:     { href: https://wiki.henrydowd.dev, description: Offline wiki }
    # added as they go live:
    # - Paperless:   { href: https://paperless.henrydowd.dev, description: Documents }
    # - Vaultwarden: { href: https://vault.henrydowd.dev, description: Passwords }
    - AMP:       { href: https://amp.henrydowd.dev, description: Game server }
```

Note: a ConfigMap edit doesn't hot-reload — homepage watches its config dir
but a k8s ConfigMap remount lags, so after editing config
`kubectl -n homepage rollout restart deploy/homepage`.

---

## Step 3: deploy + smoke test

```bash
argocd app get homepage --grpc-web        # Synced/Healthy — not just pods (values-drift gotcha)
curl -s https://dash.henrydowd.dev -o /dev/null -w '%{http_code}\n'   # LAN path, valid wildcard cert
curl -s -H "Host: dash.henrydowd.dev" http://192.168.1.200/ -I        # Traefik-direct (tunnel-path equivalent)
```

Then browser: `http://dash.lan` and `https://dash.henrydowd.dev` (LAN), and
off-wifi via the tunnel. If every request 400s with a host-validation error,
`HOMEPAGE_ALLOWED_HOSTS` is unset/wrong — that's the one gotcha that will bite.
Click through a couple of service links to confirm they resolve.

Re-verify Longhorn volumes are still healthy afterward (new-PVC replica-drift
gotcha) — though homepage adds none, run it out of habit when adding any app.

---

## Step 4: widgets + API keys (do this AFTER phase-8 gating)

Once `dash.henrydowd.dev` is behind Authelia ForwardAuth (`one_factor` —
add its rule + the ingress annotation in the Authelia plan's step 4; gate only
the `henrydowd.dev` host, leave `dash.lan` bare, cookie-domain gotcha):

1. `SealedSecret` `homepage-widgets` with per-service keys — Grafana
   service-account token, Immich API key, Gitea token, Proxmox API token
   (id + secret), etc. Mount as env, referenced from `services.yaml` widgets
   as `{{HOMEPAGE_VAR_GRAFANA_TOKEN}}`.
2. Add `widget:` blocks under each service (type + url + key). Keep widget
   targets on cluster-internal URLs where possible (e.g.
   `http://grafana.monitoring.svc:80`) so the polling stays in-cluster and
   doesn't loop back out through the tunnel.
3. VictoriaMetrics needs no key (no auth) — a good first widget to prove the
   pattern before minting tokens.

---

## Step 5: aftercare

- **Docs**: `services.md` (+ Dashboard row, note the auth state), HOMELAB.md
  Live Services (never commit), `adding-a-service` runbook already covers the
  ingress/netpol steps.
- **Capacity**: add to `docs/reference/capacity-headroom.md` (~40–80Mi).
- **Backup**: none — stateless, config is in git. A pod loss re-renders from
  the ConfigMap.
- **Phase 8 hook**: record in the Authelia plan's ACL table that
  `dash.henrydowd.dev` → `one_factor`.

## `home.dowd.ie` — costed as an alternative, built, then removed

**Taken, then reversed.** Both names shipped, and `home.dowd.ie` was removed on
2026-09-03 because it could not be gated without a second Authelia cookie
domain (ADR 018). Every cost listed below was paid and has now been unwound:
the Ingress rule, the per-Ingress `tls:` block, the `*.dowd.ie` Certificate in
the homepage namespace, and the `HOMEPAGE_ALLOWED_HOSTS` entry are all gone,
and the orphaned `dowd-ie-tls` Secret was deleted by hand.

The cloudflared route and the Technitium record — the two "external, not in
repo" items below — still exist. The section is kept as the checklist for
removing them, and as the price list if a second apex is ever wanted again.

`dash.henrydowd.dev` was the default precisely because it's free. `home.dowd.ie`
is the nicer name but `dowd.ie` is a separate Cloudflare zone and costs the
full file-parser treatment:

- **Cert**: the `dowd-ie-tls` wildcard secret lives in the *file-parser*
  namespace, and a plain `Ingress` `tls.secretName` only resolves
  same-namespace (the dowd-ie-cert-wrong-namespace lesson). So either add a
  second `Certificate` for `*.dowd.ie` issuing into the homepage ns, or
  duplicate the cert there — then a per-Ingress `tls:` block for `home.dowd.ie`
  (the deliberate ADR-007 exception, same as file-parser's Ingress).
- **Tunnel**: the `*.henrydowd.dev` wildcard route doesn't match `dowd.ie` —
  add an explicit cloudflared public-hostname route for `home.dowd.ie` → the
  same Traefik origin (host-routed by the Ingress), like `secure.dowd.ie`.
- **DNS**: a Technitium record `home.dowd.ie` → 192.168.1.200 for LAN.
- **Access**: while it existed it was deliberately kept out of every Cloudflare
  Access application, which is exactly what blocked step 4. Putting it behind
  Access was ADR 018's middle option; removing the host won instead.

Three extra moving parts for a prettier hostname, and a fourth that only became
visible after phase 8: a second apex cannot share the `henrydowd.dev` session
cookie, so `home.dowd.ie` could not be gated by Authelia without its own cookie
domain, `auth.dowd.ie`, and everything that name needs — permanently, to protect
a duplicate of a hostname already covered. That fourth cost is why the name was
dropped rather than kept. **If a second apex is ever wanted again, price the
auth in from the start, not just the cert, tunnel and DNS.**

## Failure modes

- `HOMEPAGE_ALLOWED_HOSTS` unset/stale ⇒ every request 400s. The single most
  likely bring-up failure.
- A YAML typo in `services.yaml` ⇒ homepage renders an error card but the pod
  stays up; check the container logs.
- ~~`home.dowd.ie` public + ungated ⇒ the link grid is world-readable.~~ Closed
  2026-09-03 by removing the host. Gating `dash.henrydowd.dev` alone had not
  changed it — the failure mode was a second hostname on the same pod, not a
  missing middleware.
- A keyed widget added before gating ⇒ live infra data leaks publicly. Don't
  add `widget:` blocks until step 4's precondition holds.
