# Authelia

Current state of the SSO stack, as deployed. Decisions and their reasoning are
in `docs/adr/018-authelia-sso.md`; the traps are in `gotchas.md`. This file is
what exists.

Version **4.39.20**, namespace `authelia`, one replica on `k3s-worker1`.
Last verified 2026-09-03.

## Role

Authelia is a ForwardAuth gate in front of four public hostnames. Traefik asks
it about every request to a gated host and either serves the request or
redirects to the portal. It does not replace the backend's own login — Proxmox
and AMP still ask for their own credentials afterwards.

OIDC is **not deployed**. Every service listed as "native" in `services.md`
still uses its own accounts.

## Request flow

Two paths reach the same pods, and only one is gated.

```
Internet → Cloudflare edge → cloudflared → Traefik :80 (web)  → forceproto → forwardauth → backend
LAN      → Technitium (192.168.1.200)   → Traefik :443 (websecure)                       → backend
```

The LAN path carries no middleware and is ungated by design. That is the
break-glass route when Authelia is down. Both paths resolve the same public
hostnames, so `https://proxmox.henrydowd.dev` from the LAN bypasses Authelia
entirely.

Cloudflare Access sits in front of Authelia on `proxmox.henrydowd.dev` and on
the `file-parser` hosts. On Proxmox that means three sequential logins from the
internet: Access, then Authelia `two_factor`, then PVE.

## What is gated

| Host | Policy | Gated on | Ungated path |
|---|---|---|---|
| `wiki.henrydowd.dev` | one_factor | Ingress `kiwix/kiwix` | `wiki.lan` via `kiwix/kiwix-lan` |
| `dash.henrydowd.dev` | one_factor | Ingress `homepage/homepage` | `dash.lan` via `homepage/homepage-ungated` |
| `amp.henrydowd.dev` | two_factor | Ingress `amp/amp` | `amp.lan` via `amp/amp-lan` |
| `proxmox.henrydowd.dev` | two_factor | IngressRoute `proxmox/proxmox`, `web` route only | `proxmox.lan`, and the same host over LAN HTTPS via `proxmox-websecure` |
| `auth.henrydowd.dev` | — | portal, `forceproto` only | — |

The ungated names are separate Ingress objects, not extra rules on the gated
ones. That separation is what makes the break-glass path survive a bad
annotation on the gated object.

`home.dowd.ie` used to serve the same pod as `dash.henrydowd.dev` on a second
apex, so it could not share the `henrydowd.dev` session cookie and left the
dashboard world-readable even after `dash` was gated. **Removed 2026-09-03**
(ADR 018), so the only hostnames on that pod are now the gated
`dash.henrydowd.dev` and the trusted-network `dash.lan`. The dashboard is
private, and phase 9's keyed live-data widgets are unblocked.

Rules live in `access_control.rules` in the ConfigMap, in plain git. A rule is
inert until the matching Ingress carries the middleware, so rules can ship
ahead of enforcement. The inverse is not safe: annotating a host with no rule
gives it a hard 403 from `default_policy: deny`.

## Kubernetes objects

All in `k8s/apps/authelia/`, synced by the `authelia` ArgoCD Application with
`prune: true, selfHeal: true`.

| File | Object | Notes |
|---|---|---|
| `namespace.yaml` | Namespace | Explicit per ADR 014. No `Prune=false` — the DB is regenerable |
| `deployment.yaml` | Deployment | 1 replica, `Recreate`, pinned to `k3s-worker1`, `enableServiceLinks: false` |
| `configmap.yaml` | ConfigMap `authelia-config` | The whole config, mounted read-only at `/config` |
| `sealed-secrets.yaml` | SealedSecret `authelia-secrets` | 4 keys |
| `sealed-users.yaml` | SealedSecret `authelia-users` | `users.yml` |
| `pvc.yaml` | PVC `authelia-data` | 1Gi Longhorn RWO |
| `service.yaml` | Service | Ports **named** `http` (9091) and `metrics` (9959) |
| `ingress.yaml` | Ingress | `auth.henrydowd.dev`, `forceproto` only |
| `middleware.yaml` | Middleware `forwardauth` | |
| `middleware-proto.yaml` | Middleware `forceproto` | |
| `networkpolicy.yaml` | NetworkPolicy | Default-deny ingress, 9091 + 9959 allowed |
| `seal-secrets.sh` | script | One-time bring-up / rotation |

`enableServiceLinks: false` matters here more than elsewhere: a Service named
`authelia` would inject `AUTHELIA_PORT` into the pod, and Authelia reads
`AUTHELIA_*` env vars as configuration.

## Middlewares

Two, in the `authelia` namespace, referenced cross-namespace. Order is fixed:

```
authelia-forceproto@kubernetescrd,authelia-forwardauth@kubernetescrd
```

**`forceproto`** sets `X-Forwarded-Proto: https`. Required on every host reached
through the tunnel, including the portal. Authelia returns 400 for any target
with an `http` scheme, and cloudflared delivers to Traefik's `web` entrypoint as
plain HTTP.

**`forwardauth`** points at
`http://authelia.authelia.svc.cluster.local:9091/api/authz/forward-auth` with
`trustForwardHeader: true` and passes down `Remote-User`, `Remote-Groups`,
`Remote-Email`, `Remote-Name`. Nothing consumes those headers today.

Cross-namespace references need `providers.kubernetesCRD.allowCrossNamespace=true`
on Traefik (`k8s/infrastructure/traefik.yaml:34`). Without it the router 404s
silently.

`trustForwardHeader: true` is safe only because Traefik's
`forwardedHeaders.trustedIPs` is empty, so Traefik overwrites any client-supplied
`X-Forwarded-For` with the real peer address. **Never add the pod CIDR
`10.42.0.0/16` to `trustedIPs` or to the `lan` network** — tunnel traffic
arrives from it, so either change makes the entire internet count as LAN.

## Configuration

Key settings from `configmap.yaml`:

| Section | Setting | Value |
|---|---|---|
| `server` | `address` | `tcp://0.0.0.0:9091` |
| | `buffers.read` / `write` | **16384** — 4096 431s the Proxmox check once PVE sets its cookies |
| | `disable_healthcheck` | `true`, required by `readOnlyRootFilesystem` |
| `authentication_backend` | file | `/secrets/users/users.yml`, argon2, `watch: true` |
| `session` | name | `authelia_session` |
| | expiration / inactivity / remember_me | 12h / 2h / 1 month |
| | cookie domain | `henrydowd.dev` only, portal `https://auth.henrydowd.dev` |
| `regulation` | | 3 retries / 2 min window / 5 min ban |
| `storage` | local | `/data/db.sqlite3` |
| `notifier` | SMTP | Brevo relay, `disable_startup_check: true` |
| `ntp` | | `disable_failure: true` |
| `telemetry` | metrics | `tcp://0.0.0.0:9959` |
| `access_control` | `default_policy` | `deny` |
| | network `lan` | `192.168.1.0/24` |

One cookie domain is what makes a single login work across all four hosts. It
is also why there is no `auth.lan`: a host matching no `session.cookies` domain
serves the portal HTML but 403s every API call.

Two startup checks are deliberately declawed. The SMTP check is disabled
because a relay that refuses the connection is otherwise fatal, which would let
a Brevo outage 502 every gated service. NTP logs a warning instead of blocking
startup. The trade is that a bad SMTP credential fails silently until someone
needs a reset email.

The image tag is pinned exactly because the config schema drifts between 4.x
minors and Authelia refuses to start on an unknown key. A floating tag turns an
unattended autosync into a cluster-wide auth outage.

## Users

One user, in `authelia-users`:

```yaml
users:
  henry:
    disabled: false
    displayname: 'Henry'
    password: '<argon2id hash>'
    email: henry@dowd.ie
    groups: [admins]
```

No ACL rule references groups today. `watch: true` means a resealed users file
is picked up without a pod restart.

## Secrets

`authelia-secrets` holds `jwt_secret`, `session_secret`,
`storage_encryption_key`, `smtp_password`. All mounted as **files** at
`/secrets/authelia/` and read via `AUTHELIA_*_FILE` env vars, never as literal
env values — an env value shows up in `kubectl describe pod`.

`storage_encryption_key` is under the same loss policy as `RESTIC_PASSWORD`:
lose it and `db.sqlite3` is unreadable. It belongs in the password manager.

`seal-secrets.sh` is not idempotent. Re-running generates new secrets, which
invalidates every session and orphans the existing TOTP database. It refuses to
overwrite without `--force`.

`authelia-oidc` is a **second, separate** Secret holding one key, `oidc.yml`,
mounted at `/secrets/oidc/`. It exists because the OIDC jwks private key cannot
be delivered the way the four above are: it is a structured list entry
(`key_id`/`algorithm`/`use`/`key`), not a scalar, so no `AUTHELIA_*_FILE` env
var can carry it. Instead the deployment passes a second `--config`, and
Authelia deep-merges the two files — the ConfigMap contributes
`identity_providers.oidc.clients`, this Secret contributes `hmac_secret` and
`jwks`, and both are live at once.

That the merge is *deep* rather than a replace is load-bearing and was verified
against 4.39.20, because a shallow merge would silently discard every client
and only surface later as `invalid_client` on an app that looks correct. The
check: put a deliberately invalid client in the ConfigMap half, then run
`validate-config` with both files. It reports the client error and stops
reporting "jwks is required", which is only possible if both halves survived.
`seal-oidc.sh` carries this note.

`seal-oidc.sh` is likewise not idempotent: rotating the jwks key invalidates
every issued ID token and every consent already granted. It refuses to
overwrite without `--force`. Losing these is *not* fatal the way
`storage_encryption_key` is — re-running mints a new provider identity at the
cost of re-consent — but they belong in the password manager anyway.

Per-client secrets come from `new-oidc-client.sh`, which prints two values that
must go to two different places: the **digest** into `configmap.yaml` (a PBKDF2
hash, safe in plain git, same as the argon2 password hashes), and the
**plaintext** into the client application. Given a namespace and secret name it
also seals the plaintext, but writes the file into `k8s/apps/authelia/` — move
it to the consuming app's ArgoCD path or it is never applied.

## Storage and backup

PVC `authelia-data`, 1Gi Longhorn RWO, holding SQLite: TOTP enrolments, OIDC
consents (unused), and the brute-force ledger. Actual size is single-digit MB.

**Not backed up, and deliberately not `Prune=false`.** ADR 018 treats it as
regenerable — one user re-enrolling TOTP takes a minute. Revisit if the
household grows past one or two enrolments.

## Security posture

Pod runs as uid/gid 1000, `runAsNonRoot`, all capabilities dropped,
`readOnlyRootFilesystem: true`, `seccompProfile: RuntimeDefault`. `fsGroup:
1000` lets the kubelet chown the Longhorn mount so SQLite can be created.

The read-only rootfs works only because `disable_healthcheck: true` stops the
boot-time write to `/app/.healthcheck.env`. Writable paths are the PVC at
`/data` and an emptyDir at `/tmp`.

NetworkPolicy is default-deny ingress, allowing 9091 and 9959 from the pod CIDR
and from both node IPs (kubelet probes come from the node, not a pod). Egress
is open — Brevo SMTP and NTP both leave the cluster.

## Monitoring

Metrics on `:9959`, scraped by `k8s/apps/monitoring/authelia-scrape.yaml`
(a **VMServiceScrape**, not a ServiceMonitor). Two alerts in
`homelab-rules.yaml`:

- **`AutheliaDown`** — `up{job="authelia"} == 0` for 3m, critical. Authelia is
  the only workload whose failure takes other services down: while it is
  unavailable every gated host 502s from the internet.
- **`AutheliaMetricsAbsent`** — `absent(up{job="authelia"})` for 15m, warning.
  Guards the alert above; if the scrape breaks, `up` stops existing rather than
  going to 0 and `AutheliaDown` can never fire.

The scrape selects the Service by the `app: authelia` label and the endpoint by
the port **name** `metrics`.

## Operations

Validate the config before any image bump:

```bash
sed -n '/^  configuration.yml: |$/,$p' k8s/apps/authelia/configmap.yaml \
  | tail -n +2 | sed 's/^    //' > /tmp/c.yml
docker run --rm -v /tmp:/c \
  -e AUTHELIA_IDENTITY_VALIDATION_RESET_PASSWORD_JWT_SECRET=$(head -c20 /dev/zero|tr '\0' a) \
  -e AUTHELIA_STORAGE_ENCRYPTION_KEY=$(head -c20 /dev/zero|tr '\0' a) \
  docker.io/authelia/authelia:4.39.20 authelia validate-config --config /c/c.yml
```

Without the two dummy env vars it reports those secrets as missing, which is
expected and not a config error.

**A ConfigMap change alone does not take effect.** The deployment carries no
config checksum annotation, so ArgoCD updates the ConfigMap and leaves the old
process running. Restart explicitly:

```bash
kubectl -n authelia rollout restart deploy/authelia
```

Test a public path for real — split-horizon DNS hides Cloudflare from the LAN:

```bash
ip=$(dig +short wiki.henrydowd.dev @1.1.1.1 | grep -E '^[0-9]' | head -1)
curl -s -o /dev/null -w '%{http_code} %{redirect_url}\n' \
  --resolve wiki.henrydowd.dev:443:$ip https://wiki.henrydowd.dev/
```

Degate everything: remove the `router.middlewares` annotations from the four
gated Ingresses and the `middlewares:` block from the Proxmox `web` route. One
commit.

Rate limits are in-memory. A pod restart clears both the elevation limiter and
the regulation ban.

## Current measurements

| | |
|---|---|
| Memory | ~98Mi resident (request 128Mi, limit 512Mi) |
| CPU | ~1m idle |
| Restarts | 0 |
| PVC | Bound, Longhorn healthy, 1 replica |

## Known constraints

Full detail in `gotchas.md`; these are the ones that recur.

- `forceproto` must come **before** `forwardauth`, and the portal needs it too.
  Missing it works on the LAN and fails from the internet.
- The 4096-byte default read buffer 431s the Proxmox check once PVE sets its
  cookies. Presents as a broken Proxmox login, not an Authelia fault.
- `maxResponseBodySize` appears in Authelia's own Traefik guide but is not a
  field in the Middleware CRD. `kubectl apply --dry-run=server` catches this
  class of error; kubeconform in CI does not.
- Verification that only reaches a backend's login page does not exercise the
  cookie state that follows a successful backend login.

## OIDC

The provider is live as of 2026-09-03. Discovery is at
`https://auth.henrydowd.dev/.well-known/openid-configuration` and resolves from
the LAN, the internet and **in-cluster** (Technitium -> Traefik -> the wildcard
cert; verified from a pod, `ssl_verify: 0`). Endpoints sit under `/api/oidc/`,
which is not the path most `generic_oauth` examples assume — read them out of
the discovery document rather than copying a blog post.

Registered clients:

| Client | Policy | Redirect URI | Notes |
|---|---|---|---|
| `grafana` | `one_factor` | `https://grafana.henrydowd.dev/login/generic_oauth` | PKCE S256, `client_secret_basic`, `consent_mode: implicit` |
| `gitea` | `two_factor` | `https://git.henrydowd.dev/user/oauth2/authelia/callback` | **No PKCE** — Gitea cannot send one, see below |
| `nextcloud` | `two_factor` | `https://nextcloud.henrydowd.dev/apps/user_oidc/code` | PKCE S256 (verified, then enforced); `user_oidc` 8.11 |
| `immich` | `two_factor` | `/auth/login`, `/user-settings`, `app.immich:///oauth-callback` | PKCE S256; **three** URIs, mobile included |
| `paperless` | `two_factor` | `/accounts/oidc/authelia/login/callback/` | PKCE S256; **trailing slash** matters |

Two per-client settings that cannot be copied between clients, both of which
were got wrong first time:

| Client | `token_endpoint_auth_method` | PKCE |
|---|---|---|
| `grafana` | `client_secret_basic` | S256 |
| `gitea` | `client_secret_basic` | **none — cannot send one** |
| `nextcloud` | **`client_secret_post`** | S256 |
| `immich` | **`client_secret_post`** | S256 |
| `paperless` | **`client_secret_post`** | S256 (off by default, enabled explicitly) |

Grafana and Gitea both authenticate through `golang.org/x/oauth2`, whose
`AuthStyleAutoDetect` tries HTTP Basic first, so `client_secret_basic` suits
them. Nextcloud's `user_oidc` puts the credentials in the token request **body**
and does not negotiate. Authelia enforces exactly what is registered, so a
mismatch fails at the *token* endpoint — after the user has already logged in
and been redirected back — with "the OAuth 2.0 client registration does not
allow this method".

### Verify a client without a browser

**An authorization redirect proves nothing about the token exchange.** Checking
that a client reaches `?flow=openid_connect` exercises none of the client
authentication, which is why the Nextcloud mismatch survived every check and
surfaced only on a real login. This is the same shape as the Proxmox 431: a
check that confirmed *reaching* something rather than *completing* it.

Probe client auth directly with a deliberately invalid code. `invalid_grant`
means the client authenticated and only the code was rejected — which is the
pass. `invalid_client` means the registration is wrong:

```bash
# client_secret_post clients (nextcloud)
curl -s -X POST https://auth.henrydowd.dev/api/oidc/token \
  -d grant_type=authorization_code -d code=bogus \
  -d redirect_uri='<the registered redirect_uri>' \
  -d client_id='<id>' -d client_secret='<plaintext>'

# client_secret_basic clients (grafana, gitea)
curl -s -u '<id>:<plaintext>' -X POST https://auth.henrydowd.dev/api/oidc/token \
  -d grant_type=authorization_code -d code=bogus \
  -d redirect_uri='<the registered redirect_uri>'
```

Run this for every new client before calling it done.

`one_factor` rather than `two_factor` because Grafana is reachable only from
the LAN, so the network already does the work a second factor would. amp and
proxmox are `two_factor` because they are reachable from the internet.

**Grafana moved to a new hostname for this.** OIDC needs an HTTPS origin inside
the `henrydowd.dev` cookie domain, and `grafana.lan` is neither. The new host is
served by a `websecure`-only Ingress
(`k8s/apps/monitoring/grafana-ingress.yaml`), which makes it LAN-only *by
construction* rather than by absence of a tunnel route — see the wildcard-tunnel
entry in `gotchas.md`, because the obvious reasoning here is wrong and would
have published Grafana to the internet. `grafana.lan` stays, un-annotated, as
the break-glass path, and Grafana's password login stays enabled: it is where
you look when the cluster is unwell, so its only door must not be a pod that
might itself be what is down.

### Gitea: the auth source is not in git

Gitea is the one client whose configuration cannot be fully declarative.
`[oauth2_client]` in `k8s/apps/gitea/deployment.yaml` controls the *behaviour*
of an OAuth login (account linking, auto-registration, which claim becomes the
username), but the auth **source** — client id, secret, discovery URL — lives in
Gitea's SQLite DB and there is no app.ini equivalent. It is created once:

```bash
POD=$(kubectl -n gitea get pod -l app=gitea -o jsonpath='{.items[0].metadata.name}')
kubectl -n gitea exec $POD -c gitea -- su git -c "gitea admin auth add-oauth \
  --name authelia \
  --provider openidConnect \
  --key gitea \
  --secret '<plaintext from new-oidc-client.sh>' \
  --auto-discover-url https://auth.henrydowd.dev/.well-known/openid-configuration \
  --scopes openid --scopes profile --scopes email --scopes groups \
  --group-claim-name groups \
  --admin-group admins"
```

`su git` is required: the container runs as root (the capless-root shape of ADR
011) and Gitea refuses to run its CLI as root. `gitea admin auth list` shows the
result; `update-oauth --id N` edits it.

**The `--name` is load-bearing.** Gitea builds its callback from the source name,
`/user/oauth2/<name>/callback`, not from the client id — so renaming the source
silently breaks the `redirect_uris` registered in Authelia.

Because this lives only in the DB, it is a genuine gap in the repo's
"git is the source of truth" property: a rebuild from an empty database comes up
with SSO missing and no sync error to say so. `cluster-rebuild.md` lists it as a
post-restore step.

**Gitea sends no PKCE.** Its openidConnect source (goth, 1.24) omits
`code_challenge` entirely and `add-oauth` has no flag to enable it, so this
client is registered `require_pkce: false`. Grafana keeps PKCE. This surfaced as
a rejected authorization request, *behind* a more obvious fault — see Operations
for why a ConfigMap edit alone does nothing.

### Nextcloud: also not in git

Same shape as Gitea — the provider lives in Nextcloud's database, not in a
manifest. Created once, with the secret passed by **environment variable** so it
never reaches argv:

```bash
POD=$(kubectl -n nextcloud get pod -l app=nextcloud -o jsonpath='{.items[0].metadata.name}')
kubectl -n nextcloud exec $POD -- env NC_OIDC_SECRET='<plaintext>' \
  su -s /bin/sh www-data -c '
php occ user_oidc:provider Authelia \
  --clientid=nextcloud \
  --clientsecret-env=NC_OIDC_SECRET \
  --discoveryuri=https://auth.henrydowd.dev/.well-known/openid-configuration \
  --scope="openid profile email groups" \
  --unique-uid=0 \
  --mapping-uid=preferred_username \
  --mapping-display-name=name \
  --mapping-email=email \
  --check-bearer=0'
```

**`--unique-uid=0` is the account-linking setting and the one to get right.**
Left at 1, user_oidc derives a hashed Nextcloud user id from the provider and
creates a *new* account; at 0 it uses the `mapping-uid` claim verbatim, so
Authelia's `preferred_username: henry` lands on the existing `henry` account.
The equivalent of Gitea's `ACCOUNT_LINKING = auto`, but it fails the other way —
silently duplicating rather than refusing.

`--check-bearer=0` keeps WebDAV and the sync clients on app passwords rather
than validating bearer tokens against Authelia. That is deliberate: it is what
lets the desktop and mobile clients keep working untouched, and is the reason
the plan put Nextcloud on OIDC instead of ForwardAuth.

The `user_oidc` app itself is installed from the app store
(`occ app:install user_oidc`) and lives on the data PVC, so it survives restarts
but not a rebuild from empty. Listed in cluster-rebuild.md alongside Gitea's.

### Immich: config lives in Postgres, and was set by SQL

Immich has no `IMMICH_CONFIG_FILE` here, so its settings live in the database —
table `system_metadata`, key `system-config`, a JSONB object holding only the
values that differ from default. It is normally edited in Admin → Settings →
OAuth; it was set here with an **additive JSONB merge**, which is safe precisely
because the row holds overrides only:

```sql
UPDATE system_metadata
SET value = value || '{"oauth": { ... }}'::jsonb
WHERE key = 'system-config';
```

`||` replaces the `oauth` key and leaves every other override (`map`,
`newVersionCheck`) untouched. Read the row back with
`jsonb_pretty(value #- '{oauth,clientSecret}')` to inspect it without printing
the secret. Restart `deploy/immich-server` afterwards.

Settings worth knowing:

- **`tokenEndpointAuthMethod: client_secret_post`** — Immich's own default, read
  out of `server/dist/config.js` rather than guessed, after Nextcloud's
  mismatch. Must match the Authelia registration.
- **`autoRegister: false`.** Immich matches an OAuth login to an existing user
  **by email**, so `henry@dowd.ie` links to the existing admin account. Left at
  its default `true`, any future Authelia identity would silently get a new
  Immich account. There is a second household user (`loridowd1@gmail.com`) who
  has no Authelia account and keeps password login — which is the reason to
  care.
- **`issuerUrl` is the full `/.well-known/openid-configuration` URL**, not the
  bare issuer. Confirmed working: discovery runs server-side, so a wrong value
  fails immediately rather than at login.

Immich performs discovery server-side when building the authorization URL, which
makes it verifiable without a browser:

```bash
curl -s -X POST https://immich.henrydowd.dev/api/oauth/authorize \
  -H 'Content-Type: application/json' \
  -d '{"redirectUri":"https://immich.henrydowd.dev/auth/login"}'
```

A URL back means discovery, client id and PKCE are all good; a 500 means
discovery failed. Repeat it with `app.immich:///oauth-callback` and
`/user-settings` to prove the other two registered URIs.

### Paperless: two env vars, and one of them fails silently

Config is entirely declarative here — no database step, unlike Gitea, Nextcloud
and Immich. It needs **both**:

```yaml
- { name: PAPERLESS_APPS, value: "allauth.socialaccount.providers.openid_connect" }
- name: PAPERLESS_SOCIALACCOUNT_PROVIDERS
  valueFrom:
    secretKeyRef: { name: paperless-oidc, key: PAPERLESS_SOCIALACCOUNT_PROVIDERS }
```

**`PAPERLESS_APPS` is the one that is easy to miss, and its absence is silent.**
django-allauth only registers a provider's URLs when its app is in
`INSTALLED_APPS`, and paperless builds that list with `*env_apps` from
`PAPERLESS_APPS` (`settings/__init__.py`, lines 126 and 153). Without it the
provider JSON parses fine, the env var is present and correct in the pod, the
pod starts clean, and **nothing appears in the logs** — there is simply no
`/accounts/oidc/…` route and no SSO button. What found it was enumerating the
registered URL patterns:

```bash
kubectl -n paperless exec deploy/paperless -- sh -c "cd /usr/src/paperless/src && python -c \"
import django, os; os.environ.setdefault('DJANGO_SETTINGS_MODULE','paperless.settings'); django.setup()
from django.urls import reverse
print(reverse('openid_connect_callback', kwargs={'provider_id':'authelia'}))\""
```

That also *is* the authoritative redirect URI — reverse it rather than copying
one, and note the trailing slash.

The provider blob is a Secret because it carries the client secret inline. Two
of its `settings` are pinned rather than negotiated, both read out of allauth
65.16.1: `token_auth_method: client_secret_post` (its OIDC adapter otherwise
decides by inspecting `token_endpoint_auth_methods_supported`, which Authelia
answers with *both* basic and post) and `oauth_pkce_enabled: true` (allauth's
`pkce_enabled_default` is `False`).

**Account linking needs a manual step here**, unlike the others. Paperless's
`henry` carries the placeholder email `root@localhost`, which does not match
Authelia's `henry@dowd.ie`, and `PAPERLESS_SOCIALACCOUNT_ALLOW_SIGNUPS` is off
so SSO cannot mint a second account. Log in with the password once and connect
the Authelia identity from the Paperless profile page. (Fixing that placeholder
email would also work, and is worth doing anyway.)

### Not yet wired

optionally argocd. Deliberately **not**
pre-registered: a client registration is only useful once its app is wired, and
minting a secret months early means a plaintext to keep safe with nothing using
it. `configmap.yaml` carries the intended redirect URIs as a comment; add each
client in the commit that wires its app.

Constraints already known: argocd is LAN-only, so it needs the same
websecure-only treatment Grafana got, or its redirect URI sits outside the cert
and cookie domain; paperless must be OIDC and never ForwardAuth, because
Paperless Mobile hits `/api`; Collabora gets neither. Several of those backends
set substantial session cookies of their own, so re-check the read buffer as
clients are added.
