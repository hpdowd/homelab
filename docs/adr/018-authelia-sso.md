# ADR 018: Authelia as the SSO layer, with the LAN deliberately outside it

**Status:** Accepted
**Date:** 2026-09-02
**Superseded By:** None

## What problem this solves

Eleven services are reachable from the internet through the cloudflared tunnel
and, until now, only two of them had an authentication layer in front of the
app itself: file-parser and Proxmox, both behind Cloudflare Access policies.
Everything else was protected by whatever login the application happened to
ship with. For Nextcloud, Immich, Gitea and Paperless that is a real login. For
AMP it is a control panel that can start and stop game servers on LXC 102,
published to the internet with nothing in front of it. For Kiwix and the
homepage dashboard there is no login at all.

*(Corrected 2026-09-03: the phase-8 plan asserted throughout that Proxmox was
"public with no CF Access today", and the first draft of this ADR repeated it.
It is not true — `proxmox.henrydowd.dev` redirects to
`hpd-homelab.cloudflareaccess.com` and always did. The claim survived because
nobody tested the public path from outside the LAN, where split-horizon DNS
hides Access entirely. See the stacking note below.)*

That is a wide and uneven perimeter, and the unevenness is the problem more than
any single service is: I could not answer "what is required to reach X from
outside" without opening the manifest for X. Authelia gives one answer for
every host — a single login, a single session cookie across `henrydowd.dev`,
and one file listing which hosts require one factor and which require two.

It also unblocks something concrete. Phase 9 shipped the household dashboard
with links only and no live-data widgets, because widgets mean Grafana, Immich
and Proxmox API keys rendered into a world-readable page. Gating the dashboard
is the precondition for adding them.

## Why Authelia and not the alternatives

**Authentik** is the obvious competitor and is more capable: a real admin UI,
flow builder, LDAP outpost, SCIM. It also wants a Postgres and a Redis and runs
a server plus a worker, which is four processes and something like 1GiB before
it does anything. The worker node has ~2.6GiB of headroom above the
`NodeMemoryLowWorker` floor on a bad day (capacity-headroom.md) and RAM is the
binding constraint on this cluster. Authelia is one Go binary at ~100Mi with a
YAML file for config, and this is a household of one or two people. The
capability I would be buying is capability I would never use, paid for in the
scarcest resource I have.

**Cloudflare Access for everything**, extending what file-parser already does,
was the other serious option and it is genuinely tempting: no pod, no PVC, no
RAM, and the auth happens at Cloudflare's edge before traffic ever enters the
house. I rejected it on two counts. It only protects the tunnel path, so it can
never be the answer for anything reached on the LAN, which means it is a second
system rather than a replacement for one. And it makes Cloudflare a hard
dependency for reaching my own services; the whole point of running this at home
is that the failure modes are mine. It stays in place for file-parser, which is
a deliberate belt-and-braces on the one service holding other people's
documents.

**Stacking on Proxmox is an open question.** Because Access was already there,
reaching the Proxmox UI from the internet now costs three sequential logins:
Cloudflare Access, then Authelia at `two_factor`, then PVE's own. That is
defensible for the highest-value target in the house and it is genuinely
belt-and-braces — the two systems fail independently, and Access stops traffic
before it enters the network at all. It is also a lot of friction for a
hypervisor you tend to reach for when something is already wrong. Left stacked
for now because removing a working control is not something to do casually, and
because the LAN path is ungated anyway, which is the one that matters during an
incident. Revisit if the friction bites.

**LLDAP as a users backend** was rejected for the same reason as Authentik:
another pod and another database so that a two-entry user list can be edited in
a web UI instead of a YAML file.

## What I picked

| Decision | Choice | Why |
|---|---|---|
| Provider | Authelia 4.39.20, pinned exactly | one binary, ~100Mi; the config schema drifts between 4.x minors and it hard-fails on unknown keys, so a floating tag is an unattended outage |
| Users backend | file (`users.yml`) | one or two humans; LLDAP is a service and a database to avoid editing YAML |
| Storage | SQLite on a 1Gi Longhorn PVC | no HA requirement; Postgres is another pod for a few MB of TOTP secrets |
| Sessions | in-memory | single replica. A restart logs everyone out, which is a mild annoyance, not an outage. Redis is a pod to avoid it |
| Cookie domain | one cookie on `henrydowd.dev` | one login across every gated host |
| Portal | `https://auth.henrydowd.dev` | resolves identically on LAN and internet via split-horizon; in-cluster reachback works since ADR 007 |
| `users.yml` | SealedSecret, never plain git | argon2 hashes are not catastrophic in public, but they are not free either |
| 2FA | TOTP now, WebAuthn later | Proxmox and AMP are public and reach real infrastructure |
| Integration | ForwardAuth for browser-only apps, OIDC for the rest | see below |

**ForwardAuth vs OIDC is decided by whether a non-browser client exists.**
ForwardAuth is strictly better where it applies: the app needs no support for
it, and an unauthenticated request never reaches the app at all. But it
intercepts *every* request to the host, so it breaks any client that is not a
browser carrying a session cookie. Immich's mobile app, Nextcloud's DAV and
desktop clients, `git push` over HTTPS to Gitea, and Paperless Mobile all talk
to `/api` directly and would break. Those get OIDC, where the app stays in
charge of its own sessions. Collabora gets neither: Nextcloud calls it
server-side over WOPI, and there is no user in that conversation to
authenticate.

## The LAN is deliberately outside the perimeter

Every gated service keeps an ungated path: `wiki.lan`, `dash.lan` and `amp.lan`
are served by separate bare Ingress objects, and Proxmox's `proxmox-websecure`
IngressRoute serves both its names on the LAN with no middleware, so a LAN
client reaching `https://proxmox.henrydowd.dev` under split-horizon DNS
bypasses Authelia entirely.

This is a choice and not an oversight, so it is worth stating plainly what it
costs and what it buys. It costs the property that gating a hostname gates it
everywhere; anyone already on the LAN is trusted, and if that assumption ever
breaks — a compromised device, an untrusted guest on the same VLAN — Authelia
does nothing to help.

What it buys is that Authelia cannot lock me out of the machines I would need to
repair Authelia. It runs on the cluster, on a node hosted by the very hypervisor
its most valuable rule protects. A failed pod, a bad config sync, a corrupted
session database or an image bump that trips the schema check would otherwise
take the Proxmox web UI with it, and the recovery path for "the cluster is
broken" cannot itself depend on the cluster being healthy. There is a real
circular-dependency failure here and the LAN bypass is what breaks the cycle. I
would rather hold the LAN as a trust boundary — which it already is for SSH and
for the Longhorn and ArgoCD UIs — than own a lockout risk on the hypervisor.

The internet-facing paths, which are the ones that were genuinely
unauthenticated before this phase, are all gated.

## Deferred: the `dowd.ie` hosts

The homepage answers on `home.dowd.ie` as well as `dash.henrydowd.dev`, on a
second Cloudflare zone with its own certificate. A second apex cannot share the
`henrydowd.dev` session cookie, so ForwardAuth on it would redirect-loop the
same way a `.lan` host does, and giving it its own cookie domain means a second
portal hostname with its own certificate, tunnel route and DNS record.

Deferred rather than solved: `home.dowd.ie` stays public and ungated for now,
and the decision between dropping the host, putting it behind a Cloudflare
Access policy, or giving Authelia a second cookie domain is left open.

**The consequence has to be recorded because it is easy to forget:** gating
`dash.henrydowd.dev` does *not* make the dashboard private while the same pod
answers unauthenticated on `home.dowd.ie`. Phase 9's keyed live-data widgets
therefore remain unsafe to add, even though the precondition they were written
against now technically reads as met. That stays blocked until this is settled.

## Two failure modes closed in configuration

**A mail outage must not be an auth outage.** Authelia's SMTP notifier runs a
startup check by default, and a relay that refuses the connection is fatal —
verified against 4.39.20, where a bad password produces `SMTP AUTH failed: 535`
and the process exits. Left alone, a rotated Brevo key or Brevo simply being
down at the wrong moment would stop Authelia starting and 502 every gated
service: an email problem escalated into a cluster-wide auth outage. The check
is disabled. A broken relay now costs only password-reset and verification
mail, which is what it should cost. The trade is that a bad credential fails
quietly until someone needs a reset, so proving a reset email actually arrives
is a required step during bring-up rather than a nicety.

*Verified 2026-09-03:* the Brevo relay works. TOTP enrolment sent its identity
-verification code and the mail arrived, which exercises exactly the path the
disabled startup check no longer covers.

**Nor must a time-server outage be one.** The NTP check exists because TOTP
depends on the clock and is worth keeping, but `disable_failure` downgrades an
unreachable time server from fatal to a logged warning. The nodes get their
time from the Proxmox host; Authelia's probe is a second opinion, not the
mechanism.

## Backup: the database is regenerable, and is not backed up

`db.sqlite3` holds TOTP enrolments, OIDC consent grants and the brute-force
regulation ledger. None of it is authored — losing it costs each user one
re-enrolment scan of a QR code, and consent grants regenerate on next login.
Compare that against what a backup would cost: another CronJob, another restic
repo, another B2 path, another `BackupJobMissing` alert to maintain.

So no backup, and correspondingly **no `Prune=false`** on the namespace or the
PVC. ADR 014 reserves that guard for data that cannot be recreated — Nextcloud
files, Immich photos, Gitea history — and applying it here would dilute a signal
that is currently precise.

The genuinely unrecoverable material is elsewhere and is already protected: the
`storage_encryption_key`, without which the database is unreadable, and the
sealed `users.yml`. Both live in git as SealedSecrets and in the password
manager, under the same loss policy as `RESTIC_PASSWORD`. Losing those is not a
restore problem, it is a rebuild-from-scratch problem, which is exactly why they
are held in two places.
