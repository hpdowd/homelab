# Phase 8: Authelia SSO implementation walkthrough

*Drafted 2026-06-12. **Reviewed 2026-09-02** against the live repo: phases 9
and 10 landed in between and moved several assumptions below, and two steps were
wrong about manifests that already exist. Every change carries an inline
"revised 2026-09-02" marker; the unmarked text is the original draft and still
holds. Verify Authelia minor version + config keys against the docs for the
exact pinned image before each step, config schema drifts between 4.x minors.*

> ## Status: PHASE 8 COMPLETE — all six OIDC clients wired, 2026-09-03
>
> Step 5 is finished. `grafana`, `gitea`, `nextcloud`, `immich`, `paperless` and
> `argocd` are all registered and deployed; grafana, gitea, nextcloud and immich
> are confirmed by real human logins. Paperless and argocd pass every check that
> does not need a browser and are awaiting a first login.
>
> Two corrections this step forced on the plan, both already applied below:
> ArgoCD did **not** stay on `argocd.lan` — it got the same websecure-pinned
> `henrydowd.dev` host Grafana did, because the plan's "LAN-only via
> split-horizon, no tunnel route" premise was wrong. And the five clients were
> registered one commit at a time as their apps were wired, rather than up
> front.
>
> The single most transferable lesson, learned the expensive way on Nextcloud:
> **an authorization redirect proves nothing about the token exchange.**
> `token_endpoint_auth_method` and `require_pkce` differ per client and fail
> only after a successful login. `docs/reference/authelia.md` carries a
> bogus-code probe that catches both without a browser.
>
> ---
>
> ## Superseded status: ForwardAuth complete; OIDC provider live with Grafana wired, 2026-09-03
>
> **Update, later on 2026-09-03.** Step 5a (the OIDC provider) is done and
> Grafana is its first client. Discovery answers on
> `https://auth.henrydowd.dev/.well-known/openid-configuration` from the LAN,
> the internet and in-cluster; Grafana's login page offers "Sign in with
> Authelia"; and the authorization request is accepted by Authelia and turned
> into an `openid_connect` flow rather than an `invalid_client`. The four
> ForwardAuth'd hosts still gate correctly at the Cloudflare edge and every LAN
> break-glass path still answers 200. **What is NOT yet verified is a real
> human login through the flow** — that needs a password and a TOTP code.
>
> Two corrections this step forced on the text below.
>
> **Step 5's "grafana and argocd are LAN-only, so their redirect URIs sit
> outside the cert/cookie domain" is answered, but its premise was wrong.** The
> plan assumed a `*.henrydowd.dev` name with no cloudflared route would be
> LAN-only. It is not: the tunnel carries a wildcard public hostname, so a name
> nobody configured still reaches Traefik from the internet, and a plain
> Ingress for `grafana.henrydowd.dev` would have published Grafana. Pinning the
> Ingress to the `websecure` entrypoint is what makes it LAN-only, because the
> tunnel only ever arrives on `web`. Same trap family as the `forceproto` 400
> and the Proxmox/Access claim: split-horizon DNS hid the public path again.
> ArgoCD needs the same treatment if it is ever done.
>
> **The other five clients are deliberately not pre-registered**, against 5b's
> "one per commit" framing — see the ADR. Their redirect URIs live as a comment
> in `configmap.yaml`.

## Superseded status: COMPLETE and verified end to end, 2026-09-03
>
> Authelia 4.39.20 is live, `Synced/Healthy`, scraped and alerted on. Four hosts
> are gated and verified **through the real Cloudflare path**: `wiki`, `amp`,
> `dash` and `proxmox` on `henrydowd.dev`. Every LAN path (`wiki.lan`,
> `amp.lan`, `dash.lan`, and Proxmox over HTTPS on both its names) still answers
> 200 — the break-glass route, deliberate per ADR 018.
>
> **The human half is done too.** Login works, TOTP is enrolled, the
> identity-verification email arrived (so the Brevo relay is confirmed — the one
> thing the disabled SMTP startup check no longer covers), and Proxmox has been
> reached from end to end through the full stack: Cloudflare Access, then
> Authelia at `two_factor`, then PVE's own login.
>
> **The ForwardAuth half of phase 8 is therefore finished.**
>
> **Still outstanding:** step 5, the OIDC provider and its clients (grafana,
> gitea, nextcloud, immich, paperless, argocd). None of it is written, and it is
> the natural next session.
>
> ### What the rollout caught
>
> Landing kiwix first as a canary paid for itself immediately. The LAN path
> redirected correctly while the real internet path returned **400**, because
> Authelia refuses any target with an `http` scheme and cloudflared delivers to
> Traefik's `web` entrypoint as plain HTTP. Fixed with a `forceproto` headers
> middleware chained ahead of `forwardauth`; had all four services been gated in
> one commit, all four would have broken publicly at once while looking fine
> from the LAN.
>
> That fix was then applied one ingress short. The portal's own Ingress needs
> `forceproto` too — without it, 2FA enrolment fails with *"Failed to generate
> One-Time Code"*, which reads as a mail fault but is really
> `invalid X-Forwarded-Proto header value 'http'` on the session-elevation
> endpoint. Both traps are written up in gotchas.md.
>
> It also disproved a claim this plan repeated throughout — that Proxmox was
> "public with no CF Access". It was not; Access was already in front of it, and
> split-horizon DNS had hidden that from every test anyone had run.
>
> ### Found after this block was first written (2026-09-03)
>
> A third trap of the same family. Authelia's default 4096-byte
> `server.buffers.read` is too small for the forward-auth check on
> `proxmox.henrydowd.dev` once PVE has issued its own cookies: Traefik replays
> the whole client header set, so `CF_Authorization` + `authelia_session` +
> `PVEAuthCookie` + `CSRFPreventionToken` together cross the limit and Authelia
> answers **431** without parsing the request. Raised to 16384.
>
> The symptom lied the same way the other two did — Authelia was passed
> cleanly, and the *Proxmox* login appeared to be broken. It also means the
> verification recorded above was real but incomplete: it confirmed *reaching*
> Proxmox, not *logging into* it, so the four-cookie state was never exercised.
> Re-verified by a human after the fix.
>
> Two things generalise to step 5. A ConfigMap change needs an explicit
> `kubectl -n authelia rollout restart deploy/authelia` (no checksum annotation
> on the deployment), and several OIDC clients — Nextcloud and Gitea in
> particular — set substantial session cookies of their own, so the buffer is
> worth re-checking as they are added.

Architecture: Authelia is the identity provider. Two integration modes, and a
standing list of what stays out of both:

- **ForwardAuth** (Traefik middleware) for apps with no/weak native auth that
  are only used in a browser: kiwix, proxmox, amp, and the homepage dashboard.
- **OIDC** for apps with native SSO support and non-browser clients that
  ForwardAuth would break: grafana, gitea (git over https), nextcloud (DAV),
  immich (mobile app), paperless (Paperless Mobile hits `/api`), optionally
  argocd.
- **Neither, deliberately** (revised 2026-09-02, these shipped or were decided
  after the draft): collabora is a WOPI backend Nextcloud calls server-side, so
  auth in front of it breaks editing; portfolio is the public CV site and holds
  no secrets by design (ADR 009); vaultwarden (phase 11) is the auth root and
  gating it is circular; file-parser already sits behind a Cloudflare Access
  policy on both hostnames and stays there rather than moving to Authelia.

WireGuard stays network-layer, untouched. Decisions to record in ADR 018
before starting (step 0).

---

## Step 0: ADR 018 + preflight

**Renumbered 2026-09-02.** This said ADR 014, which was taken on 2026-07-22 by
the explicit-namespaces prune guard. 015 is paperless, 016 is spoken for by the
phase-11 Vaultwarden plan, 017 is the bootstrap layer; Authelia's ADR is
**018**. Write `docs/adr/018-authelia-sso.md` recording:

| Decision | Choice | Why |
|---|---|---|
| Users backend | file (`users.yml`) | 1–2 users; LLDAP = +1 service +RAM for nothing |
| Storage | SQLite on Longhorn 1Gi | no HA need; PG = +1 pod |
| Sessions | in-memory | single replica; restart logs everyone out — fine |
| Cookie domain | `henrydowd.dev` | one session across all subdomains |
| Issuer / portal | `https://auth.henrydowd.dev` | same URL on LAN + tunnel (split-horizon); in-cluster reachback works since ADR 007 |
| users.yml location | SealedSecret, NOT plain git | argon2 hashes don't belong in plain git |
| 2FA | TOTP now, WebAuthn later | proxmox/amp public exposure warrants two_factor |
| Prune guard (ADR 014) | decide together with the step-6 backup row | *revised 2026-09-02*: the namespace is a managed, prunable object now. Treat the TOTP DB as regenerable and it needs no `Prune=false`; back it up instead and guard the namespace + PVC the way nextcloud/immich/gitea are |
| `*.dowd.ie` hosts | not covered by the cookie; gate at the edge or drop the host | *revised 2026-09-02*: `home.dowd.ie` is a second apex outside the `henrydowd.dev` cookie domain and serves the same homepage pod. **Resolved 2026-09-03: dropped the host** — the option this row named first |

Preflight:

```bash
# RAM headroom (want worker comfortably under the NodeMemoryLowWorker gate)
kubectl top nodes
# Current Authelia release — pin EXACTLY (helm-version gotcha applies to images too)
# https://github.com/authelia/authelia/releases
```

*Revised 2026-09-02:* take that `kubectl top` reading fresh rather than trusting
`capacity-headroom.md`, whose last real measurement is 2026-07-23 and predates
both the paperless bulk ingest and the nextcloud pin to the worker. Authelia at
~100Mi resident will fit regardless; the reason to look is that the worker's 7d
minimum was 2.66GiB against a 2GiB `NodeMemoryLowWorker` floor at that last
reading, and known-risks open action 7 (limits at 191% of allocatable) is still
open.

DNS and tunnel need **zero work**: `*.henrydowd.dev` and `*.lan` wildcards
already point at 192.168.1.200, and cloudflared already routes the public
wildcard. `auth.henrydowd.dev` resolves the moment the Ingress exists.

---

## Step 1: secrets

**Superseded 2026-09-02 by `k8s/apps/authelia/seal-secrets.sh`.** Run it from
anywhere; it cd's to its own directory and writes the two sealed files there:

```bash
./k8s/apps/authelia/seal-secrets.sh
```

It prompts once for the `henry` login password and does everything else itself:
reads the image tag out of `deployment.yaml` so the argon2 parameters match the
version that will actually run, generates the three 64-char randoms, pulls the
**existing** Brevo key straight out of the `alertmanager-smtp` secret in the
cluster rather than having it retyped, builds `users.yml`, and seals both
secrets against the in-cluster controller. Plaintext only ever exists in a
`mktemp -d` that is removed on exit, including on failure.

At the end it prints the generated values once. **Put them in the password
manager then**, under the same loss policy as `RESTIC_PASSWORD` — the
`storage_encryption_key` especially, because without it `db.sqlite3` is
unreadable and every TOTP enrolment is gone. They are not recoverable from the
sealed files.

Two notes on why this is a script and not the command list that used to be
here. The old list opened with `openssl rand -hex 64`, and **there is no
`openssl` on this workstation** (nor `xxd`); `authelia crypto rand` is used
instead, which also removes a dependency since the container is needed for the
argon2 hash anyway. And re-running rotates every secret, invalidating all
sessions and orphaning the existing database, so the script refuses to
overwrite without `--force`.

---

## Step 2: deploy, LAN smoke test, nothing enforced yet

### Step 2a: landing order (added 2026-09-02)

The working tree contains both the Authelia app *and* the enforcement. Land it
as **two** functional commits with a human gate between them, so the gate is
never "I hope this works" but "I have logged in".

```bash
# 1. Authelia itself + the Traefik flag it needs + monitoring + ADR.
#    Enforces NOTHING: no annotations anywhere, and the ACL rules in the
#    ConfigMap are inert until a middleware sends traffic to Authelia.
git add k8s/apps/authelia k8s/apps/authelia.yaml \
        k8s/apps/monitoring/authelia-scrape.yaml \
        k8s/apps/monitoring/homelab-rules.yaml \
        k8s/infrastructure/traefik.yaml \
        docs/adr/018-authelia-sso.md docs/adr/README.md
git commit -m "authelia: deploy the provider, nothing enforced yet"
```

Note that the Traefik Application is `automated` + `selfHeal`, so this rolls
Traefik to pick up `--providers.kubernetescrd.allowCrossNamespace=true`. One
replica, but `maxSurge` brings the replacement up before the old one goes, so
the ingress should not actually drop.

**Then stop and prove it works**, from a browser, before anything is gated:
log in at `auth.henrydowd.dev`, enrol TOTP, and trigger a password reset —
**do not continue until that email arrives.** The SMTP startup check is
deliberately off (ADR 018), so a wrong relay credential will not announce
itself any other way, and password reset is how you get back in if the
password is ever lost.

```bash
# 2. Enforcement. Splits kiwix/amp/homepage into gated-public + bare-LAN
#    Ingress objects and puts the middleware on the Proxmox tunnel route.
#    This is the commit that can lock a public hostname.
git add k8s/apps/kiwix/ingress.yaml k8s/apps/amp/ingress.yaml \
        k8s/apps/homepage/ingress.yaml k8s/apps/proxmox/ingress-route.yaml \
        docs/reference/services.md docs/runbooks/cluster-rebuild.md \
        docs/plans/phase-8-authelia.md
git commit -m "authelia: gate kiwix, amp, dashboard and the proxmox tunnel"
```

The annotations ship *with* the splits, so this is not the strict
one-service-per-commit rollout the original draft imagined. If you want that,
drop the `annotations:` block from amp and homepage before committing and add
them back one commit at a time; kiwix alone is then the canary.

The LAN paths stay open throughout, so a mistake at any point is recoverable
from `wiki.lan` / `dash.lan` / `amp.lan` / `proxmox.lan`.

### Manifests

Manifests in `k8s/apps/authelia/` **plus** `k8s/apps/authelia.yaml`
(root-app is non-recursive, no top-level yaml = silently orphaned):

- `namespace.yaml` — still correct, and now mandatory: ADR 014 (2026-07-22)
  made every app declare its own namespace and removed `CreateNamespace=true`
  repo-wide, so the Application must **not** reintroduce that sync option
  (revised 2026-09-02)
- `configmap.yaml`, `configuration.yml` (sketch below)
- `pvc.yaml`; 1Gi Longhorn (verify volume comes up `healthy`/1 replica after)
- `deployment.yaml`, single replica, **strategy: Recreate** (RWO gotcha),
  pinned to worker like everything else, `requests: 128Mi/100m`,
  `limits: 512Mi`. Secrets mounted as files + `AUTHELIA_*_FILE` env vars:
  - `AUTHELIA_IDENTITY_VALIDATION_RESET_PASSWORD_JWT_SECRET_FILE`
  - `AUTHELIA_SESSION_SECRET_FILE`
  - `AUTHELIA_STORAGE_ENCRYPTION_KEY_FILE`
  - `AUTHELIA_NOTIFIER_SMTP_PASSWORD_FILE`
  - probes: `GET /api/health` on 9091
- `service.yaml`, port 9091 (+ 9959 metrics, step 6)
- `ingress.yaml`, **`auth.henrydowd.dev` only**, `ingressClassName: traefik`,
  **no** entrypoints annotation, **no** tls block (ADR 007). *Revised
  2026-09-02:* the draft also listed `auth.lan`, and it was dropped after
  testing showed the portal returns 200 for the HTML but **403 on every API
  call** for a host that matches no `session.cookies` domain — a login page
  that renders and then refuses every submission. `auth.henrydowd.dev` already
  resolves on the LAN via split-horizon, so nothing is lost. Reasoning is in
  the manifest header.

`configuration.yml` core (verify keys against pinned version's docs):

```yaml
server:
  address: tcp://0.0.0.0:9091
log:
  level: info
totp:
  issuer: auth.henrydowd.dev
identity_validation:
  reset_password: {}            # jwt_secret via env file
authentication_backend:
  file:
    path: /secrets/users/users.yml
    password:
      algorithm: argon2
session:
  cookies:
    - domain: henrydowd.dev
      authelia_url: https://auth.henrydowd.dev
regulation:                     # brute-force lockout
  max_retries: 3
  find_time: 2m
  ban_time: 5m
storage:
  local:
    path: /data/db.sqlite3
notifier:
  smtp:
    address: submission://smtp-relay.brevo.com:587
    username: ae07ea001@smtp-brevo.com
    sender: "Authelia <same sender alertmanager uses>"
access_control:
  default_policy: deny
  networks:
    - name: lan
      networks: ["192.168.1.0/24"]   # NEVER add 10.42.0.0/16 — that's the pod
                                     # CIDR; tunnel traffic arrives from it
  rules: []                          # filled in step 4
```

Smoke tests (in order):

```bash
argocd app get authelia --grpc-web        # Synced/Healthy — not just pods (values-drift gotcha)
curl -s https://auth.henrydowd.dev -o /dev/null -w '%{http_code}\n'   # LAN path, valid wildcard cert
curl -s -H "Host: auth.henrydowd.dev" http://192.168.1.200/ -I        # Traefik-direct (tunnel-path equivalent)
```

Then in a browser: log in, **enroll TOTP**, and trigger a password reset to
prove the Brevo notifier works, identity verification emails gate
everything later; do not proceed past this step until the email arrives.

---

## Step 3: ForwardAuth middleware

One middleware in the authelia namespace, referenced cross-namespace.

**3a. Traefik values** (`k8s/infrastructure/traefik.yaml`). Re-checked
2026-09-02: `allowCrossNamespace` is still absent from the live values and the
chart is still pinned `34.5.0`, so this step stands exactly as drafted.

```yaml
providers:
  kubernetesCRD:
    enabled: true
    allowCrossNamespace: true
```

Per the inline-values gotcha: `helm template traefik/traefik --version 34.5.0
-f <extracted values>` and confirm `--providers.kubernetescrd.allowcrossnamespace=true`
renders before committing; check `argocd app get traefik` after.

**3b. Middleware** (`k8s/apps/authelia/middleware.yaml`):

```yaml
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: forwardauth
  namespace: authelia
spec:
  forwardAuth:
    address: http://authelia.authelia.svc.cluster.local:9091/api/authz/forward-auth
    authResponseHeaders: [Remote-User, Remote-Groups, Remote-Email, Remote-Name]
```

Reference syntax (the silent-404 gotcha, one typo drops the whole router):

- Ingress annotation: `traefik.ingress.kubernetes.io/router.middlewares: authelia-forwardauth@kubernetescrd`
  (format is `<middleware-namespace>-<name>@kubernetescrd`, cf. the existing
  `nextcloud-nextcloud-wellknown@kubernetescrd`)
- IngressRoute (proxmox): `spec.routes[].middlewares: [{name: forwardauth, namespace: authelia}]`

**Client-IP note:** Traefik does not trust upstream `X-Forwarded-For` by
default, so tunnel requests reach Authelia with the cloudflared pod IP
(10.42.x) and LAN requests with the real 192.168.1.x, exactly what the
`lan` network rule needs. Don't add `forwardedHeaders.trustedIPs` for the
pod CIDR; that would let the internet spoof LAN.

---

## Step 4: enforcement, one service per commit

ACL rules (added to configmap as each service is gated):

```yaml
rules:
  - domain: wiki.henrydowd.dev
    policy: one_factor
  # dash.henrydowd.dev (homepage, phase 9): gate ONLY the henrydowd.dev host —
  # leave dash.lan bare (cookie-domain redirect-loop). Gating here is the
  # precondition for adding the keyed live-data widgets (phase-9 step 4).
  # The same pod ALSO answered on home.dowd.ie, which no rule here could cover
  # (second apex, outside the cookie domain), so this gate did not make the
  # page private on its own. Settled 2026-09-03 by removing that host, so the
  # precondition now genuinely holds. Revised 2026-09-02, updated 2026-09-03.
  - domain: dash.henrydowd.dev
    policy: one_factor
  - domain: [proxmox.henrydowd.dev, amp.henrydowd.dev]
    policy: two_factor
  # optional LAN softening — LAN gets 1FA where internet needs 2FA:
  # - domain: proxmox.henrydowd.dev
  #   networks: [lan]
  #   policy: one_factor     # order matters: first match wins, put before the 2FA rule
```

`.lan` hostnames are NOT in the cookie domain (`henrydowd.dev`), ForwardAuth
on a `.lan` ingress would redirect-loop. Gate only the `henrydowd.dev` rule
in dual-host ingresses.

**Splitting the Ingress is mandatory, not conditional (revised 2026-09-02).**
The draft said "split them into two Ingress objects if needed", which
understates the work: the middleware annotation attaches to the **Ingress
object**, not to a host rule inside it, so annotating any of these gates every
host that object carries, `.lan` included. Every service in this step is a
single dual-host object today — kiwix (`wiki.lan` + `wiki.henrydowd.dev`), amp
(`amp.henrydowd.dev` + `amp.lan`), homepage (`dash.lan` +
`dash.henrydowd.dev` + `home.dowd.ie`) — so each one gets split into an
annotated public Ingress and a bare `.lan` Ingress **before** the annotation
goes anywhere near it. That split is the first commit of each sub-step below,
and it's a no-op on its own, which makes it a safe thing to land and verify
separately. LAN staying bare is the accepted outcome, not a compromise.

**The `home.dowd.ie` problem (new 2026-09-02, decide before 4a).** Homepage
grew a third hostname on a separate Cloudflare zone after this plan was
drafted, and it is deliberately kept out of any Cloudflare Access app so it
stays public. It serves the same pod as `dash.henrydowd.dev`. That matters more
than it looks: the *entire point* of gating the dashboard is to make the keyed
live-data widgets safe to add (phase-9 step 4), and gating
`dash.henrydowd.dev` while `home.dowd.ie` answers the same content unauthenticated
achieves none of that. Being a second apex, it cannot be covered by the
`henrydowd.dev` session cookie, so ForwardAuth on it would redirect-loop the
same way a `.lan` host does. Four ways out, cheapest first:

1. **Drop `home.dowd.ie` from the homepage Ingress** and let
   `dash.henrydowd.dev` be the public name. Cheapest and my recommendation
   unless the household actually types the short one; also lets the
   `dowd-ie-tls` Certificate and its ADR-007 exception come out of
   `k8s/apps/homepage/`.
2. **Put it behind a Cloudflare Access policy**, the way file-parser's two
   hosts already are. Keeps the hostname, adds a second auth system in front of
   one app, and the household then has two different login experiences for the
   same dashboard.
3. **Add a second cookie domain** for `dowd.ie` in `session.cookies`. Authelia
   supports it, but each cookie domain needs its own `authelia_url`, so this
   pulls in `auth.dowd.ie`: another cert, another tunnel public-hostname route,
   another Technitium record, all for one hostname.
4. **Accept it stays public** and keep the dashboard links-only forever. Honest,
   but it forfeits the widgets, which is most of the reason to do this phase.

**Decided 2026-09-02: option 4, deferred.** Build around `henrydowd.dev` for
now; `home.dowd.ie` stays public and ungated and will be dropped or gated
later. Recorded in ADR 018. The consequence carries: the homepage's keyed
widgets stay blocked, because the pod behind `dash.henrydowd.dev` is still
answering anonymously on the other hostname. That warning is written into
`k8s/apps/homepage/ingress.yaml` and services.md so it cannot be quietly
forgotten.

**4a. Kiwix first** (lowest risk, no native auth): split
`k8s/apps/kiwix/ingress.yaml` into `wiki.henrydowd.dev` and `wiki.lan` objects
and sync that alone first, then annotate the public one, sync, then verify the
full matrix:

```bash
curl -s -H "Host: wiki.henrydowd.dev" http://192.168.1.200/ -I   # expect 302 → auth.henrydowd.dev
```

- LAN browser: redirect → login → redirected back with session
- Tunnel (phone off wifi): same flow
- Second service later: no login prompt (cookie domain works)

**4b. Proxmox** — `two_factor` policy. *Correction 2026-09-03: this plan said
"the prize, public with no CF Access today" in several places and that was
simply wrong.* `proxmox.henrydowd.dev` redirects to
`hpd-homelab.cloudflareaccess.com` and always did; the error survived because
the public path was never tested from outside the LAN, where split-horizon DNS
resolves the name to Traefik and hides Access completely. Authelia therefore
*adds* a layer rather than supplying the first one, and the internet path now
costs three logins (Access → Authelia → PVE). See ADR 018's stacking note. **Decided 2026-09-02: gate the tunnel path only.** The middleware goes
on the `proxmox` route's `Host(proxmox.henrydowd.dev)` rule and
`proxmox-websecure` is left alone, so LAN HTTPS to either hostname bypasses
Authelia. That is deliberate: Proxmox is where you go to fix the cluster, and
Authelia runs on it — gating the LAN path would let a broken auth pod lock you
out of the hypervisor hosting it. The reasoning is written into the manifest
header and ADR 018. Everything below about splitting `proxmox-websecure` is
therefore **not** being done. Verify the noVNC console still works (websockets pass ForwardAuth once
the session cookie exists). The Proxmox login screen remains after Authelia;
that's expected; Authelia is perimeter, PVE auth stays.

**Proxmox has two IngressRoutes, and neither takes the middleware as-is
(revised 2026-09-02).** The draft said "middleware on its IngressRoute",
singular; `k8s/apps/proxmox/ingress-route.yaml` actually holds two, because a
`tls` block makes a route TLS-only and 404s the plain-HTTP tunnel, so one route
could never serve both paths:

- `proxmox` (`web`, no tls) carries the tunnel on `Host(proxmox.henrydowd.dev)`
  plus a separate `Host(proxmox.lan)` rule that only redirects to HTTPS. Add
  `forwardauth` to the `henrydowd.dev` rule's `middlewares` list and leave the
  redirect rule alone.
- `proxmox-websecure` (`websecure`, `tls: {}`) serves LAN HTTPS from **one**
  rule matching `Host(proxmox.lan) || Host(proxmox.henrydowd.dev)`. Under
  split-horizon DNS this is the route a LAN browser actually reaches for
  `proxmox.henrydowd.dev`, so leaving it ungated leaves a bypass on the LAN;
  gating the combined match takes `proxmox.lan` with it and redirect-loops.
  **Split it into two routes first**, one per host, then annotate only the
  `henrydowd.dev` one.

Re-read the Traefik/ingress gotcha and
`docs/lessons/networking/proxmox-401-secure-cookie-plain-http.md` before
touching that file: PVE issues its auth cookie `Secure`, which is what forced
the two-route arrangement, and a wrong edit here 401s the login right after it
appears to succeed rather than failing cleanly.

**4c. AMP**: same as 4b, but simpler, it's a plain dual-host Ingress
(`amp.henrydowd.dev` + `amp.lan`), so it's the kiwix split followed by the
`two_factor` rule.

**Do NOT ForwardAuth**: immich (mobile app hits `/api` directly), nextcloud
(DAV/desktop clients), gitea (`git push` over https), paperless (Paperless
Mobile, same shape, added 2026-09-02), OIDC only, step 5. Leave collabora
alone entirely: Nextcloud calls it server-side over WOPI, so neither
ForwardAuth nor OIDC belongs in front of it.

Rollback for any service = remove the annotation/middleware ref and sync.

---

## Step 5: OIDC provider + clients

**5a. Provider — DONE 2026-09-03.** Implemented as `seal-oidc.sh` (provider
key material) and `new-oidc-client.sh` (per-client secrets) rather than as the
loose commands below; the deep-merge assumption in this step was verified, not
taken on trust. Original notes kept for context:

**5a. Provider.** Generate:

```bash
openssl rand -hex 64 > hmac_secret
docker run --rm docker.io/authelia/authelia:<pinned> \
  authelia crypto pair rsa generate --bits 4096   # → jwks issuer key
# per client:
docker run --rm docker.io/authelia/authelia:<pinned> \
  authelia crypto hash generate pbkdf2 --random   # prints plaintext (give to client app) + digest (goes in authelia config)
```

`hmac_secret` via `AUTHELIA_IDENTITY_PROVIDERS_OIDC_HMAC_SECRET_FILE`. The
jwks private key can't be an env secret, put the `identity_providers.oidc.jwks`
block in a second config file mounted from a SealedSecret and add
`--config /secrets/oidc/oidc.yml` to the container args (Authelia merges
multiple `--config`).

Client registrations live in the ConfigMap (digests only, safe in git):

```yaml
identity_providers:
  oidc:
    clients:
      - client_id: grafana
        client_secret: "$pbkdf2-sha512$..."
        authorization_policy: one_factor
        # Grafana is now LAN-only (grafana.lan, no henrydowd.dev host) — same
        # bucket as ArgoCD below: this redirect URI is outside the cookie/cert
        # domain, so either accept the cert-mismatch warning on grafana.lan or
        # re-add a grafana.henrydowd.dev host just for the OIDC flow. root_url
        # is http://grafana.lan, so match the scheme here.
        redirect_uris: [http://grafana.lan/login/generic_oauth]
        scopes: [openid, profile, email, groups]
```

Discovery URL for every client:
`https://auth.henrydowd.dev/.well-known/openid-configuration`, works from
LAN, internet, AND in-cluster (Technitium → Traefik → valid wildcard cert,
the Collabora-WOPI pattern). In-cluster callers (grafana, immich, argocd)
fetch it server-side: confirm resolution from a pod if anything 500s.

**5b. Clients, easiest first, one per commit:**

| Order | App | Where | Notes |
|---|---|---|---|
| 1 ✅ | Grafana (**done**, LAN-only on `grafana.henrydowd.dev` via a websecure-pinned Ingress) | vm-stack inline values: `grafana.grafana.ini` `[auth.generic_oauth]` + secret via `grafana.envFromSecret` | confirm exact keys with `helm show values` (silent-drift gotcha); endpoints `/api/oidc/{authorization,token,userinfo}`; map `groups` → role |
| 2 ✅ | Gitea (**done**) | UI: Site Admin → Authentication Sources → OpenID Connect (or `gitea admin auth add-oauth`) | auto-discovery URL; account linking ON so existing `henry` maps; git-over-https keeps using tokens — unaffected |
| 3 ✅ | Nextcloud (**done**) | `occ app:install user_oidc` then `occ user_oidc:provider Authelia --clientid … --clientsecret … --discoveryuri …` | keep password login until mapped user verified; DAV clients keep app-passwords |
| 4 ✅ | Immich (**done**) | Admin → Settings → OAuth | issuer `https://auth.henrydowd.dev`; redirect URIs: `https://immich.henrydowd.dev/auth/login` **and** `app.immich:///oauth-callback` (mobile); keep password login enabled until both web+app proven |
| 5 ✅ | Paperless (**done**) | `PAPERLESS_SOCIALACCOUNT_PROVIDERS` (django-allauth JSON) in the deployment env + the client secret from its SealedSecret | *added 2026-09-02*: shipped as phase 10 after this plan was drafted, and both ADR 015 and services.md already promise "Authelia OIDC after phase 8", so it's a commitment, not an option. Verify the env key and JSON shape against v3.0.0's own docs before writing it, the allauth configuration moved across 2.x/3.x. Leave `PAPERLESS_DISABLE_REGULAR_LOGIN` unset until a mapped login is proven, and don't ForwardAuth it (Paperless Mobile hits `/api`) |
| 6 ✅ | ArgoCD (**done**, websecure-pinned `argocd.henrydowd.dev`, `admins` → `role:admin`) | `argocd-cm` `oidc.config` + secret in `argocd-secret` | LAN-only at `argocd.lan` = redirect URI outside the cert/cookie domain — either accept warnings or move UI to `argocd.henrydowd.dev` (LAN-only via split-horizon, no tunnel route) first. Defer if friction |

After each: log out, log in via "Sign in with Authelia", confirm the account
**linked** rather than duplicated, then (optionally, much later) disable
password login per app.

---

## Step 6: aftercare

- **Metrics**: enable in config (`telemetry.metrics.enabled: true`,
  `tcp://0.0.0.0:9959`), add port to Service, add a `VMServiceScrape`
  (copy `longhorn-scrape.yaml` pattern incl. the `absent()` guard) +
  `AutheliaDown` rule in `homelab-rules` VMRule. An auth outage takes down
  every gated service; this alert matters more than most.
- **Backup**: the SQLite DB holds TOTP/WebAuthn enrollments + OIDC consent.
  Either add it to a backup CronJob (gitea pattern: tiny, scale-to-0 not
  needed, sqlite `.backup` via `kubectl exec` is enough at this size) or
  document as regenerable (re-enroll TOTP after restore). Decide in ADR 018,
  together with its prune-guard row: "regenerable" and "no `Prune=false`" are
  the same decision, and so are "backed up" and "guarded".
- **Restore-order note** in `cluster-rebuild.md`: Sealed Secrets master key →
  Authelia synced+healthy → only then re-gate ingresses (else every gated
  service 502s while Authelia is down). ForwardAuth annotations are in git,
  so a rebuild re-gates automatically, Authelia must come up first.
- **Docs**: services.md (+auth column, and clear the two "after phase 8"
  promises at services.md's Paperless and Homepage entries), adding-a-service
  runbook (+"choose auth tier: forwardauth / oidc / native / none"),
  HOMELAB.md (never commit). Add the ADR 018 row to `docs/adr/README.md`,
  whose table is maintained by hand (revised 2026-09-02).
- **Unblocks phase 9 step 4** (revised 2026-09-02): the homepage's keyed
  live-data widgets were deferred until `dash.henrydowd.dev` sits behind
  `one_factor`, so finishing step 4 is what releases them — assuming the
  `home.dowd.ie` decision went a way that actually closes the hole. This is
  the payoff worth sequencing the phase around.
- **Capacity**: re-run the headroom report (`docs/reference/capacity-headroom.md`);
  Authelia should be ~100Mi resident.
- Re-verify Longhorn volumes healthy (new-PVC replica-drift gotcha).

## Failure modes to keep in mind

- Authelia pod down ⇒ all ForwardAuth'd services 502 (OIDC apps keep
  working on existing sessions). Single replica is the accepted trade.
- Sessions are in-memory ⇒ every Authelia restart logs everyone out of
  gated services. Annoying-but-fine; revisit Redis only if it actually hurts.
- Storage encryption key lost ⇒ DB unreadable ⇒ delete PVC, re-enroll 2FA.
  Key is sealed in git + password manager; this should never happen.
- Brevo relay down ⇒ no resets/verification emails; logins unaffected —
  **but only because the SMTP startup check is explicitly disabled.** Left at
  its default this was not true: a relay that refuses the connection is fatal,
  verified against 4.39.20, where a bad password gives `SMTP AUTH failed: 535`
  and the process exits. An email outage would have become an auth outage. The
  cost of turning it off is that a bad SMTP credential fails quietly until
  someone needs a reset mail, which is exactly what step 2's "do not proceed
  until the email arrives" gate is for. See ADR 018.
- **A gated host reachable by a second, ungated route is a silent bypass**
  (added 2026-09-02). Proxmox is the worked example — `proxmox.henrydowd.dev`
  is matched by both the `web` and the `websecure` route, so gating one leaves
  the other open and nothing warns you, the site simply keeps working. Before
  declaring any service gated, list every router that matches its hostname
  (`kubectl get ingress,ingressroute -A | grep <host>`) rather than the one you
  just edited, and re-run the LAN and tunnel curls from step 4a separately, they
  traverse different entrypoints and that is exactly the difference this failure
  mode hides in.
