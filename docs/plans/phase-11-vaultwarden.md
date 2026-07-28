# Phase 11: Vaultwarden household password manager walkthrough

*Drafted 2026-07-22. Pin the exact `vaultwarden/server:<x>-alpine` release
before deploying — the admin-token format (now argon2 PHC) and the built-in
WebSocket handling changed across 1.2x/1.3x. Verify env keys against the
pinned version's [settings
template](https://github.com/dani-garcia/vaultwarden/blob/main/.env.template).*

Architecture: one Rust container, SQLite on Longhorn. `/data` holds
`db.sqlite3` + attachments + `rsa_key` (the JWT signing key) + sends +
`config.json`. WebSocket live-sync is served on the **main HTTP port** now (no
separate `:3012` route since 1.29 — ignore old guides' websocket ingress).
~50–100Mi resident (Rust, tiny).

**Deliberately OUTSIDE Authelia and Cloudflare Access.** It's the auth root:
gating it behind Authelia is a circular dependency (you'd need to be logged in
to log in), and the Bitwarden browser extensions and mobile apps hit
`/api` + `/identity` directly — a proxy-auth in front breaks them exactly the
way ForwardAuth/Access breaks Immich's app and file-parser's clients. So:
public via the tunnel, native Vaultwarden auth + per-user 2FA only.

A `k8s/apps/vaultwarden.yaml` Application is already scaffolded locally
(untracked) pointing at an **empty** `k8s/apps/vaultwarden/` — as-is it syncs
nothing. This plan fills the dir; commit the Application alongside the
manifests.

Decisions to record in ADR 016 before starting (step 0).

## Step 0: ADR 016 + preflight

Write `docs/adr/016-vaultwarden.md`:

| Decision | Choice | Why |
|---|---|---|
| DB | SQLite on Longhorn 1Gi | Vaultwarden's recommended default for a household; Postgres = +1 pod for nothing |
| Exposure | `vault.lan` + `vault.henrydowd.dev`, public via tunnel, **no** Authelia/Access | the auth root must be reachable to unlock everything; native app/extension clients break behind proxy-auth; gating it is circular |
| Signups | `SIGNUPS_ALLOWED=false`, seed via emailed invitations (or `/admin`) | closed household set; open signups on a public instance invite abuse |
| Admin page | `ADMIN_TOKEN` as an **argon2 PHC hash**, disable after setup | plaintext token is deprecated + logs a warning; unset it once users exist |
| SMTP | Brevo relay (same key as alertmanager/authelia) | invitations, email 2FA, new-device alerts |
| 2FA | encourage TOTP/WebAuthn per user | these are the household's crown jewels |
| Push | optional Bitwarden push (id/key from bitwarden.com/host) | mobile live-sync; skippable |
| Backup | restic → B2 (new repo), online `sqlite3 .backup` (no scale-to-0) | existential — losing `/data` loses every password |

Preflight — DNS/cert/tunnel need **zero work**: `vault.henrydowd.dev` rides
the `*.henrydowd.dev` wildcard (Technitium on LAN, cloudflared publicly, LE
wildcard TLSStore cert). **Confirm `vault.henrydowd.dev` is NOT added to any
Cloudflare Access application** — it must stay open, unlike file-parser.

---

## Step 1: secrets

Admin token as an argon2 hash (interactive — prompts for the token you'll
type into `/admin`):

```bash
docker run --rm -it vaultwarden/server:<pinned> /vaultwarden hash    # prints an $argon2id$... PHC string
```

`SealedSecret` `vaultwarden-secrets`:

```bash
kubectl create secret generic vaultwarden-secrets -n vaultwarden \
  --from-literal=ADMIN_TOKEN='$argon2id$...' \
  --from-literal=SMTP_PASSWORD='<Brevo key>' \
  --dry-run=client -o yaml | kubeseal --format yaml > k8s/apps/vaultwarden/sealed-secret.yaml
```

`SMTP_PASSWORD` = the **same Brevo SMTP key** Alertmanager/Authelia use
(`alertmanager-smtp`; key is in the password manager).

Password-manager copies: the `ADMIN_TOKEN`, and — flagged as existential — the
`RESTIC_PASSWORD` for the vaultwarden repo. Same loss policy as the master
Sealed-Secrets key: lose the backup password and a `/data` loss is
unrecoverable, i.e. every household password gone.

---

## Step 2: manifests

`k8s/apps/vaultwarden/` **plus** the already-scaffolded
`k8s/apps/vaultwarden.yaml` (commit it):

- `namespace.yaml`, `sealed-secret.yaml`
- `pvc.yaml` — `vaultwarden-data` 1Gi Longhorn (verify `healthy`/1 replica
  after).
- `deployment.yaml` — single replica, **`strategy: Recreate`** (RWO gotcha),
  pinned to worker, `requests: 64Mi/50m`, `limits: 256Mi`. Run it fully
  locked down (it's security-critical, and it needs no root): set
  `ROCKET_PORT=8080` so it binds a high port and needs no `NET_BIND_SERVICE`:

  ```yaml
  securityContext:            # pod
    runAsNonRoot: true
    runAsUser: 1000
    fsGroup: 1000             # so the non-root process owns the fresh /data PVC
    seccompProfile: { type: RuntimeDefault }
  # container
  securityContext:
    allowPrivilegeEscalation: false
    capabilities: { drop: ["ALL"] }
  ```

  Env:

  ```yaml
  # LOAD-BEARING: WebAuthn/passkey origin, attachment URLs, and invite links
  # all derive from DOMAIN. A wrong or http:// value makes 2FA registration
  # silently fail. Must be the exact public https URL.
  - { name: DOMAIN,          value: "https://vault.henrydowd.dev" }
  - { name: ROCKET_PORT,     value: "8080" }
  - { name: SIGNUPS_ALLOWED, value: "false" }
  - { name: INVITATIONS_ALLOWED, value: "true" }
  - { name: SMTP_HOST,       value: "smtp-relay.brevo.com" }
  - { name: SMTP_PORT,       value: "587" }
  - { name: SMTP_SECURITY,   value: "starttls" }
  - { name: SMTP_FROM,       value: "<same sender alertmanager uses>" }
  - { name: SMTP_USERNAME,   value: "ae07ea001@smtp-brevo.com" }
  # ADMIN_TOKEN, SMTP_PASSWORD from the SealedSecret
  ```

  `/data` is the PVC (writable); nothing else needs writing, so no extra
  emptyDir. probes: `GET /alive` on 8080 (returns 200).
- `service.yaml` — port 8080.
- `ingress.yaml` — `vault.lan` + `vault.henrydowd.dev`, `ingressClassName:
  traefik`, **no** entrypoints annotation, **no** `tls:` block (ADR 007).
  Traefik passes WebSockets by default, so live-sync rides the same route — no
  special annotation, and no legacy `:3012` path.
- `networkpolicy.yaml` — default-deny-ingress + allow Traefik/probes to 8080
  (copy `kiwix`, swap the port). Egress open.

---

## Step 3: bring-up + client matrix

```bash
argocd app get vaultwarden --grpc-web     # Synced/Healthy
curl -s https://vault.henrydowd.dev/alive -o /dev/null -w '%{http_code}\n'   # 200, valid wildcard cert
```

Then:

1. `/admin` with the `ADMIN_TOKEN` — set org/general settings.
2. **Send yourself an invitation** (Users → invite) — this is the Brevo gate,
   same as Authelia's step 2: do not proceed until the email arrives, or no
   household member can be onboarded and email 2FA won't work.
3. Accept the invite, set a master password, **enrol 2FA** (TOTP/WebAuthn).
4. Verify the full client matrix — the reason this is public and unproxied:
   - **Web vault** login (`https://vault.henrydowd.dev`), LAN and off-wifi.
   - **Browser extension** — log in + confirm sync.
   - **Mobile app** off-wifi (through the tunnel).
   - **WebSocket live-sync** — edit an item on the web vault, confirm it
     pushes to the extension without a manual refresh.
5. Invite the rest of the household. Confirm `SIGNUPS_ALLOWED=false`, then
   consider unsetting `ADMIN_TOKEN` (disables `/admin`) now that users exist.

Re-verify the Longhorn volume is healthy (new-PVC replica-drift gotcha).

---

## Step 4: backup (restic → B2)

New repo `.../vaultwarden`. SQLite is small and `sqlite3 .backup` is WAL-aware
and **online-safe**, so — unlike Gitea — no scale-to-0 and no downtime:

- `backup-sealed-secret.yaml` — `backup-credentials` (`RESTIC_REPOSITORY`
  `s3:https://…/vaultwarden` — the `s3:https://` prefix is load-bearing,
  restic gotcha; `RESTIC_PASSWORD`; B2 keys).
- `backup-cronjob.yaml` — 03:15 (staggered before nextcloud 03:00… pick a slot
  clear of the others), `podAffinity` co-locating on the worker so it can mount
  the RWO `vaultwarden-data` PVC alongside the running pod (Longhorn RWO
  attaches per-node; both land on the worker — make it explicit like the Gitea
  backup). Script: `sqlite3 /data/db.sqlite3 ".backup /tmp/db.bak"` for a
  consistent snapshot, then `restic backup /tmp/db.bak` **plus** the rest of
  `/data` mounted read-only (`attachments/`, `sends/`, `rsa_key*`,
  `config.json` — all needed for a working restore; the `rsa_key` especially,
  lose it and every session/2FA re-registers). Retention 7d/4w/3m.

Add the repo + a test-restore row to `restore-procedure.md`, and treat this as
the **highest-priority** restore to actually exercise — a silent backup failure
here is the worst outcome in the whole cluster. `RESTIC_PASSWORD` to the
password manager.

---

## Step 5: aftercare

- **Docs**: `services.md` (+ Vaultwarden row — note **public, NOT behind
  Access**, so the "auth" column is native+2FA), HOMELAB.md (never commit),
  `adding-a-service` runbook.
- **Capacity**: add to `capacity-headroom.md` (~50–100Mi).
- **Monitoring**: no native Prometheus metrics — skip a VMServiceScrape. A
  `VaultwardenDown` alert still matters (household can't unlock while it's
  down); a follow-up can add a blackbox `up` probe on `/alive`, the same
  "auth-outage-matters-more-than-most" reasoning as `AutheliaDown`.
- **Attachment size**: uploads/sends >100MB fail through the Cloudflare tunnel
  (the immich cap) — fine on LAN/VPN. Note it for anyone attaching large files.

## Failure modes

- `/data` lost with no good backup ⇒ **total loss** of every household
  password. The backup is existential — hence the test-restore emphasis.
- `DOMAIN` wrong/`http://` ⇒ WebAuthn/passkey enrolment silently fails (the
  origin won't match). The most likely bring-up gotcha.
- `vault.henrydowd.dev` accidentally added to a Cloudflare Access application
  ⇒ mobile app + browser-extension sync break (the native-client lesson).
  Verify it stays absent.
- Brevo relay down ⇒ no invitations / email-2FA; existing logins unaffected.
- Vaultwarden pod down ⇒ no one can unlock — but, unlike Authelia, this does
  **not** cascade: the other services don't depend on it, so an outage is
  contained to the password manager. Single replica accepted.
