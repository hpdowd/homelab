# Incident: AMP would not log in — an empty Bearer header made Authelia ignore the session

## Date
2026-09-16 (broken since 2026-09-03)

## Time lost
~45 min to diagnose. The fault itself sat unnoticed for 13 days.

## Status
Fixed and verified. `forwardauth-noauthz` middleware, commit `6a045f0`.

## Context
- **System / component:** `amp.henrydowd.dev`, gated by Authelia ForwardAuth
  through Traefik. AMP runs on LXC 102, reached by a hand-written EndpointSlice.
- **Scope:** the public hostname only. `amp.lan` is a separate ungated Ingress
  and worked throughout, which is why this went unnoticed for two weeks.
- **State before:** phase 8 put `amp.henrydowd.dev` behind ForwardAuth on
  2026-09-03 at `two_factor`. AMP itself has not changed since 2026-07-25
  (binary built 24 July). The gating is what broke it, on the day it shipped.

## Symptoms
- Login to AMP never completes. The Authelia portal accepts the password and
  the TOTP code, returns to AMP, and the AMP UI does not come up.
- Repeating in the Authelia log, immediately after each successful login:

```text
level=error msg="Error occurred while attempting to authenticate a request"
error="failed to parse content of Authorization header: invalid scheme: the scheme is missing"
method=GET path=/api/authz/forward-auth
```

- In the browser: `POST https://amp.henrydowd.dev/API/Core/GetAPISpec` → **401**,
  response carrying `www-authenticate: Basic realm="Authorization Required"`,
  request carrying `Authorization: Bearer` — the scheme with no token after it.

## Investigation

The first thing to establish was that Authelia was not rejecting anything, and
its own database says so plainly:

```text
2026-09-16 20:32:58 | henry | success=1 | TOTP
2026-09-16 20:32:56 | henry | success=1 | 1FA
```

Both factors pass, every attempt. `requires 2FA, cannot be redirected yet` in
the log is the normal intermediate state of a `two_factor` policy, not an error.
AMP was healthy too — all four instances up, rootfs read-write.

So the failure was after a successful login, which pointed at the one anomaly
left: the Authorization header. Probing the live forward-auth endpoint with no
session gave the shape of it:

| Header sent | Response |
|---|---|
| none | 302 → portal |
| `Authorization: Bearer <token>` | 302 |
| `Authorization: Bearer` (scheme only) | **401** |
| `Authorization: sometoken` (no scheme) | **401** |
| invalid session cookie, no header | 302 |
| invalid session cookie + scheme-only Bearer | **401** |

Ruling out the server side took longer than it should have and was necessary:
`AMP.js` and `ServiceWorker.js` contain no reference to `Authorization` when
grepped from disk, AMP returns no `WWW-Authenticate` of its own, the Ingress
carries only `forceproto` + `forwardauth`, and Homepage's AMP entry is a plain
link with no widget or API key. The header is added by AMP's JS at runtime, and
only the browser's own network panel showed it.

## Root cause

Authelia treats the presence of an `Authorization` header as "this request is
from a non-browser API client". It then tries that credential **instead of** the
session cookie, and when the value will not parse the request errors out rather
than falling through to `authelia_session`.

AMP's JS calls its own API with a scheme-only `Authorization: Bearer` — no token
— before it has an AMP session to put there. Traefik replays the client's entire
header set to `/api/authz/forward-auth`, so Authelia sees that header, fails to
parse it, and answers 401 with its own `www-authenticate: Basic`. AMP never
receives its API spec, so its login form never initialises.

The session was valid the whole time and was never consulted. That is also why
logging in again never helped: the fresh session is exactly the thing being
ignored.

This is the same failure class as the Proxmox read-buffer trap — a header
introduced by the *backend* conversation breaking the *gate* — and it lies in
the same direction. Getting *through* Authelia works, so it presents as "AMP's
login is broken" and sends you into AMP.

## Fix

A second middleware, identical to the shared `forwardauth` plus
`authRequestHeaders`, which is a **whitelist** of headers copied to the auth
server. `Authorization` is absent from it. The filter applies only on the way to
Authelia, so the backend still receives the header — which matters, because AMP
uses a real Bearer token once it has one.

```yaml
# k8s/apps/authelia/middleware.yaml
name: forwardauth-noauthz
spec:
  forwardAuth:
    authRequestHeaders:
      - Cookie
      - X-Forwarded-Proto
      - X-Forwarded-Host
      - X-Forwarded-Uri
      - X-Forwarded-Method
      - X-Forwarded-For
      - Accept
      - User-Agent
```

Scoped to the `amp` Ingress rather than applied to the shared middleware. The
same trap is reachable on any gated host whose client sends an Authorization
header — a PVE API token over the tunnel would do it — but a whitelist that
silently omits a header Authelia needs breaks every gated service at once.

`authRequestHeaders` is in this cluster's Middleware CRD, unlike
`maxResponseBodySize` (see the note in `middleware.yaml`).

## Verification

Through Traefik, after the ArgoCD sync:

```text
amp.henrydowd.dev, no Authorization        -> 302   (was 302)
amp.henrydowd.dev, Authorization: Bearer   -> 302   (was 401)
amp.henrydowd.dev, Authorization: sometoken-> 302   (was 401)
wiki.henrydowd.dev                         -> 302   unchanged
dash.henrydowd.dev                         -> 302   unchanged
amp.lan                                    -> 200   unchanged
```

Still gating, not failing open: the 302 goes to
`https://auth.henrydowd.dev/?rd=https%3A%2F%2Famp.henrydowd.dev%2F&rm=GET`, and
the log shows the request denied for `<anonymous>` as it should be.
`X-Forwarded-For` survives the whitelist — Authelia logs the real `remote_ip` —
so the `lan` network rule still means something.

## Prevention

- **A gated host's client must not send an `Authorization` header Authelia will
  see.** Check this when gating anything new, because the failure appears only
  *after* a successful login and therefore never during the gating change
  itself.
- **Bisect with `Accept: text/html`, not `application/json`.** With a JSON
  Accept, Authelia answers 401 whether the bad header is present or not, since
  it content-negotiates 401-vs-302 on `Accept`. The probe then shows no
  difference and reads as "not the problem". Watch for 401-vs-302 on an HTML
  Accept instead. The unauthenticated probe cannot demonstrate the fix either —
  the only proof is a real session, which is what the browser provides.
- **`www-authenticate` on a 401 behind ForwardAuth is probably Authelia's, not
  the backend's.** It reads as the app demanding credentials and is the single
  most misleading part of this failure.
- **An ungated break-glass path hides faults on the gated one.** `amp.lan` kept
  working for 13 days and is the reason nobody noticed. That is the path doing
  its job, and it is also the argument for checking the gated hostname after
  gating it, rather than the service.

## Related
- `docs/reference/gotchas.md`, Traefik / ingress — the entry above this one is
  the Proxmox read-buffer trap, the same mechanism with the `Cookie` header.
- `docs/reference/authelia.md` — what is gated and on which Ingress.
- ADR 018 for why AMP is `two_factor` and why `amp.lan` stays ungated.
