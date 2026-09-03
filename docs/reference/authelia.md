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
| `dash.henrydowd.dev` | one_factor | Ingress `homepage/homepage` | `dash.lan` + `home.dowd.ie` via `homepage/homepage-ungated` |
| `amp.henrydowd.dev` | two_factor | Ingress `amp/amp` | `amp.lan` via `amp/amp-lan` |
| `proxmox.henrydowd.dev` | two_factor | IngressRoute `proxmox/proxmox`, `web` route only | `proxmox.lan`, and the same host over LAN HTTPS via `proxmox-websecure` |
| `auth.henrydowd.dev` | — | portal, `forceproto` only | — |

The ungated names are separate Ingress objects, not extra rules on the gated
ones. That separation is what makes the break-glass path survive a bad
annotation on the gated object.

`home.dowd.ie` is a second apex, cannot share the `henrydowd.dev` session
cookie, and serves the same pod as `dash.henrydowd.dev`. It is public and
ungated. The dashboard is therefore not private, which blocks phase 9's keyed
live-data widgets.

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

## Not implemented

OIDC (step 5 of `docs/plans/phase-8-authelia.md`). Nothing of it is written. It
needs an RSA jwks key and `hmac_secret` in a second config file mounted from its
own SealedSecret, per-client secrets, and clients for grafana, gitea, nextcloud,
immich, paperless and optionally argocd.

Constraints already known: grafana and argocd are LAN-only, so their redirect
URIs sit outside the cert and cookie domain; paperless must be OIDC and never
ForwardAuth, because Paperless Mobile hits `/api`; Collabora gets neither.
Several of those backends set substantial session cookies of their own, so
re-check the read buffer as clients are added.
