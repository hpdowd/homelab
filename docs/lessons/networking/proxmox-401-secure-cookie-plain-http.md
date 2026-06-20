# Incident: Proxmox login 401 (and public 404) — `Secure` auth cookie over plain HTTP

## Date
2026-06-20

## Time lost
~1h

## Status
Resolved.

## Context
- **System / component:** `proxmox.lan` / `proxmox.henrydowd.dev` → Traefik IngressRoute → PVE host `192.168.1.2:8006` (PVE 9.2.2). Namespace `proxmox`.
- **Scope:** Proxmox web UI *through the cluster's Traefik*. Direct `https://192.168.1.2:8006` was unaffected throughout.
- **State before:** Proxmox reached through Traefik on the `web` (plain-HTTP) entrypoint only — its IngressRoute pinned `entryPoints: [web]`, unlike every other service (plain Ingresses, bound to web + websecure). LAN HTTPS via the default wildcard cert had been in place since ADR 007 (2026-06-12).

## Symptoms
- `proxmox.lan`: login page loads, credentials accepted, then immediately **`401 user unauthorized`** — login never completes.
- `proxmox.henrydowd.dev`: **404 page not found** (Traefik's plain-text 404, not a Cloudflare error page).
- Direct `https://192.168.1.2:8006`: fully working, including login.

## Investigation
Two symptoms, one underlying cause — but they looked unrelated at first.

**The 401 (proxmox.lan):**
- Hypothesis: PVE host auth broken (clock skew / pmxcfs down / realm) → **ruled out.** `pve-cluster`/`pveproxy`/`pvedaemon` active, `/etc/pve` mounted, `authkey.key` present, host clock matched the client to the second, and **direct HTTPS login worked**.
- Hypothesis: the proxy mangles the login POST → **ruled out.** A dummy-cred POST to `/api2/extjs/access/ticket` returned byte-identical `200`/77-byte bodies proxied (`web`) vs. direct. The login request itself is relayed perfectly.
- So the failure is *after* a successful login → the session cookie isn't being honoured. Confirmed by reading PVE source on the host:
  ```text
  # /usr/share/perl5/PVE/APIServer/Formatter.pm:95
  return "${cookie_name}=$encticket; path=/; secure; SameSite=Lax;";
  ```
  The auth cookie is hardcoded **`secure`**. A browser on a plain-HTTP origin (`http://proxmox.lan`, the only entrypoint the route offered) silently drops it → the next API call carries no ticket → 401.

**The 404 (proxmox.henrydowd.dev):**
- Red herring: an in-house `curl https://proxmox.henrydowd.dev` 404'd identically (byte-for-byte) to a direct hit on Traefik's `websecure` entrypoint. That `curl` never touched Cloudflare — **Technitium split-horizon** resolves the name to `192.168.1.200` (Traefik) on the LAN, and **`henrydowd.dev`'s HSTS** forces the browser to HTTPS, so it lands on `websecure`, where proxmox had no route (it was `web`-only). The public tunnel path (`web`) was actually fine all along.

**Fixing it — two Traefik quirks, both verified with throwaway routes:**
- A CRD IngressRoute is served on the `websecure` entrypoint **only if it carries a `tls` block**. Without one: `websecure` → 404.
- But adding `tls: {}` makes the router **TLS-only** → it then **404s plain HTTP on `web`**, breaking the Cloudflare tunnel (cloudflared speaks plain HTTP — the standing "never pin websecure" gotcha).
- So one IngressRoute can't serve both. (Plain k8s Ingresses dodge this: the `kubernetesIngress` provider auto-attaches the default TLS store to them on websecure — that's why every other service "just works" on both entrypoints.)
- Dead end: live `kubectl apply` kept reverting within ~3 min — ArgoCD `selfHeal` watches the Gitea remote, so the change only sticks once committed and pushed, not applied live.

## Root cause
Proxmox's web UI must be reached **by the browser over HTTPS** — PVE issues its auth cookie `Secure`, so any plain-HTTP browser session drops it and 401s right after login. The route was `web`-only (plain HTTP), so:
- LAN over `http://proxmox.lan` → cookie dropped → 401.
- `proxmox.henrydowd.dev`, HSTS-forced to HTTPS and split-horizon'd to Traefik, hit `websecure` → no route → 404.

## Fix
Split into two IngressRoutes (+ a redirect), commit `6b5fc12`:
- `proxmox` on **`web`, no tls** — carries the Cloudflare tunnel (`proxmox.henrydowd.dev`, plain HTTP; the browser is still HTTPS at CF's edge, so the cookie survives). `http://proxmox.lan` is redirected to HTTPS via a `redirect-https` Middleware; the tunnel host is deliberately **not** redirected (cloudflared would redirect-loop).
- `proxmox-websecure` on **`websecure`, `tls: {}`** — LAN-direct HTTPS for both names, default wildcard cert (TLSStore `default`).

The manifest header comment in `k8s/apps/proxmox/ingress-route.yaml` carries the full why.

## Verification
```bash
# web (= tunnel path), plain HTTP — Proxmox answers
curl -s -o /dev/null -w '%{http_code}\n' -H 'Host: proxmox.henrydowd.dev' http://192.168.1.200/         # 200
# websecure (= LAN path), TLS — both names answer
curl -sk -o /dev/null -w '%{http_code}\n' --resolve proxmox.lan:443:192.168.1.200 https://proxmox.lan/  # 200
# http://proxmox.lan upgrades to HTTPS
curl -s -o /dev/null -w '%{http_code} %{redirect_url}\n' -H 'Host: proxmox.lan' http://192.168.1.200/    # 301 https://proxmox.lan/
```
Browser login over `https://proxmox.henrydowd.dev` (valid cert) or `https://proxmox.lan` (cert-name mismatch warning, accepted) then completes — the `Secure` cookie is retained.

## Prevention
- Any HTTPS-native backend that sets a `Secure`/`__Host-` auth cookie (Proxmox is the example) **must be reachable over HTTPS by the browser, including on the LAN** — give it a `websecure` IngressRoute with `tls: {}`, *separate* from the `web` route the tunnel uses. New gotcha filed under Traefik/ingress.
- Remember the asymmetry: plain Ingresses get websecure for free (default TLS store); a CRD IngressRoute does not — it needs an explicit `tls` block, and that block is mutually exclusive with serving plain `web` for the tunnel.

## Related
- Sibling: `docs/lessons/networking/proxmox-502-selfsigned-tunnel.md` (the self-signed `:8006` backend on the same service).
- ADR 007 — LAN TLS via the default wildcard cert this fix leans on.
- Standing gotcha "Never pin `router.entrypoints: websecure`" — this is the complementary case: a service that needs *both*, as two routes.
- Manifest: `k8s/apps/proxmox/ingress-route.yaml`; fix commit `6b5fc12`.
