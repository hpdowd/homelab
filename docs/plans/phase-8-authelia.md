# Phase 8: Authelia SSO implementation walkthrough

*Drafted 2026-06-12. Verify Authelia minor version + config keys against the
docs for the exact pinned image before each step, config schema drifts
between 4.x minors.*

Architecture: Authelia is the identity provider. Two integration modes:

- **ForwardAuth** (Traefik middleware) for apps with no/weak native auth that
  are only used in a browser: kiwix, proxmox, amp.
- **OIDC** for apps with native SSO support and non-browser clients that
  ForwardAuth would break: grafana, gitea (git over https), nextcloud (DAV),
  immich (mobile app), optionally argocd.

WireGuard stays network-layer, untouched. Decisions to record in ADR 008
before starting (step 0).

---

## Step 0: ADR 008 + preflight

Write `docs/adr/008-authelia-sso.md` recording:

| Decision | Choice | Why |
|---|---|---|
| Users backend | file (`users.yml`) | 1–2 users; LLDAP = +1 service +RAM for nothing |
| Storage | SQLite on Longhorn 1Gi | no HA need; PG = +1 pod |
| Sessions | in-memory | single replica; restart logs everyone out — fine |
| Cookie domain | `henrydowd.dev` | one session across all subdomains |
| Issuer / portal | `https://auth.henrydowd.dev` | same URL on LAN + tunnel (split-horizon); in-cluster reachback works since ADR 007 |
| users.yml location | SealedSecret, NOT plain git | argon2 hashes don't belong in plain git |
| 2FA | TOTP now, WebAuthn later | proxmox/amp public exposure warrants two_factor |

Preflight:

```bash
# RAM headroom (want worker comfortably under the NodeMemoryLowWorker gate)
kubectl top nodes
# Current Authelia release — pin EXACTLY (helm-version gotcha applies to images too)
# https://github.com/authelia/authelia/releases
```

DNS and tunnel need **zero work**: `*.henrydowd.dev` and `*.lan` wildcards
already point at 192.168.1.200, and cloudflared already routes the public
wildcard. `auth.henrydowd.dev` resolves the moment the Ingress exists.

---

## Step 1: secrets

Generate (all random, no human passwords):

```bash
openssl rand -hex 64   # x4: jwt_secret, session_secret, storage_encryption_key — and keep one spare
```

User password hash (interactive, prompts for password):

```bash
docker run --rm -it docker.io/authelia/authelia:<pinned> \
  authelia crypto hash generate argon2
```

`users.yml`:

```yaml
users:
  henry:
    displayname: Henry
    password: "$argon2id$..."   # from above
    email: henry@dowd.ie
    groups: [admins]
```

Seal everything (controller in kube-system; see operations.md):

```bash
kubectl create secret generic authelia-secrets -n authelia \
  --from-file=jwt_secret --from-file=session_secret \
  --from-file=storage_encryption_key --from-file=smtp_password \
  --dry-run=client -o yaml | kubeseal --format yaml > k8s/apps/authelia/sealed-secrets.yaml

kubectl create secret generic authelia-users -n authelia \
  --from-file=users.yml \
  --dry-run=client -o yaml | kubeseal --format yaml > k8s/apps/authelia/sealed-users.yaml
```

`smtp_password` = the **same Brevo SMTP key** Alertmanager uses
(`alertmanager-smtp` SealedSecret; key is in the password manager).

**Password-manager copies of all of it:** same loss policy as
`RESTIC_PASSWORD`. The storage_encryption_key especially: lose it and the
SQLite DB (TOTP enrollments) is unreadable.

---

## Step 2: deploy, LAN smoke test, nothing enforced yet

Manifests in `k8s/apps/authelia/` **plus** `k8s/apps/authelia.yaml`
(root-app is non-recursive, no top-level yaml = silently orphaned):

- `namespace.yaml`
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
- `ingress.yaml`, `auth.lan` + `auth.henrydowd.dev`, `ingressClassName:
  traefik`, **no** entrypoints annotation, **no** tls block (ADR 007)

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

**3a. Traefik values** (`k8s/infrastructure/traefik.yaml`):

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
  - domain: [proxmox.henrydowd.dev, amp.henrydowd.dev]
    policy: two_factor
  # optional LAN softening — LAN gets 1FA where internet needs 2FA:
  # - domain: proxmox.henrydowd.dev
  #   networks: [lan]
  #   policy: one_factor     # order matters: first match wins, put before the 2FA rule
```

`.lan` hostnames are NOT in the cookie domain (`henrydowd.dev`), ForwardAuth
on a `.lan` ingress would redirect-loop. Gate only the `henrydowd.dev` rule
in dual-host ingresses (split them into two Ingress objects if needed:
annotated public one + bare `.lan` one, LAN is trusted network anyway).

**4a. Kiwix first** (lowest risk, no native auth): annotate the ingress,
sync, then verify the full matrix:

```bash
curl -s -H "Host: wiki.henrydowd.dev" http://192.168.1.200/ -I   # expect 302 → auth.henrydowd.dev
```

- LAN browser: redirect → login → redirected back with session
- Tunnel (phone off wifi): same flow
- Second service later: no login prompt (cookie domain works)

**4b. Proxmox** (the prize, public with no CF Access today): middleware on
its IngressRoute, `two_factor` policy. Verify the noVNC console still works
(websockets pass ForwardAuth once the session cookie exists). The Proxmox
login screen remains after Authelia; that's expected; Authelia is
perimeter, PVE auth stays.

**4c. AMP**: same as 4b.

**Do NOT ForwardAuth**: immich (mobile app hits `/api` directly), nextcloud
(DAV/desktop clients), gitea (`git push` over https), OIDC only, step 5.

Rollback for any service = remove the annotation/middleware ref and sync.

---

## Step 5: OIDC provider + clients

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
        redirect_uris: [https://grafana.henrydowd.dev/login/generic_oauth]
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
| 1 | Grafana | vm-stack inline values: `grafana.grafana.ini` `[auth.generic_oauth]` + secret via `grafana.envFromSecret` | confirm exact keys with `helm show values` (silent-drift gotcha); endpoints `/api/oidc/{authorization,token,userinfo}`; map `groups` → role |
| 2 | Gitea | UI: Site Admin → Authentication Sources → OpenID Connect (or `gitea admin auth add-oauth`) | auto-discovery URL; account linking ON so existing `henry` maps; git-over-https keeps using tokens — unaffected |
| 3 | Nextcloud | `occ app:install user_oidc` then `occ user_oidc:provider Authelia --clientid … --clientsecret … --discoveryuri …` | keep password login until mapped user verified; DAV clients keep app-passwords |
| 4 | Immich | Admin → Settings → OAuth | issuer `https://auth.henrydowd.dev`; redirect URIs: `https://immich.henrydowd.dev/auth/login` **and** `app.immich:///oauth-callback` (mobile); keep password login enabled until both web+app proven |
| 5 (opt) | ArgoCD | `argocd-cm` `oidc.config` + secret in `argocd-secret` | LAN-only at `argocd.lan` = redirect URI outside the cert/cookie domain — either accept warnings or move UI to `argocd.henrydowd.dev` (LAN-only via split-horizon, no tunnel route) first. Defer if friction |

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
  document as regenerable (re-enroll TOTP after restore). Decide in ADR 008.
- **Restore-order note** in `cluster-rebuild.md`: Sealed Secrets master key →
  Authelia synced+healthy → only then re-gate ingresses (else every gated
  service 502s while Authelia is down). ForwardAuth annotations are in git,
  so a rebuild re-gates automatically, Authelia must come up first.
- **Docs**: services.md (+auth column), adding-a-service runbook (+"choose
  auth tier: forwardauth / oidc / native / none"), HOMELAB.md (never commit).
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
- Brevo relay down ⇒ no resets/verification emails; logins unaffected.
