# ADR 007 — cert-manager wildcard cert as Traefik's default: real TLS on the LAN path

**Status:** Accepted
**Date:** 2026-06
**Superseded By:** —

## What problem this solves

Split-horizon DNS sends `*.henrydowd.dev` from LAN clients straight to
Traefik (192.168.1.200), bypassing Cloudflare's edge — and with it the
only valid certificate in the system. Traefik answered LAN HTTPS with its
built-in self-signed cert, so every `https://*.henrydowd.dev` visit from
home threw a browser warning, `git push` to git.henrydowd.dev failed
SSL verification, and Collabora's WOPI reachback needed an ugly interim
hairpin (`dnsPolicy: None` + public resolvers) just to see a cert it
could trust.

## What I picked

1. **cert-manager (helm, pinned v1.20.2) + Let's Encrypt DNS-01 via
   Cloudflare.** DNS-01 is the only viable challenge: public ingress is
   tunnel-only (no port 80 to answer HTTP-01 on), and only DNS-01 can
   issue a wildcard. The Cloudflare API token (Zone:Read + DNS:Edit, same
   token the ddns script uses) lives in a SealedSecret in the
   cert-manager namespace.
2. **One wildcard Certificate (`henrydowd.dev` + `*.henrydowd.dev`) in
   the `traefik` namespace**, not per-service certs. Every service is a
   subdomain of the same zone; one secret, zero per-app ceremony.
3. **Traefik `TLSStore` named `default`** pointing at the secret. This
   makes the wildcard the cert Traefik presents on `websecure` for every
   router — existing Ingresses need no `tls:` blocks and new services get
   valid TLS for free. The chart's websecure entrypoint already has TLS
   enabled, so nothing else changed.
4. **Self-check over DoH** (`--dns01-recursive-nameservers-only` +
   `https://1.1.1.1/dns-query,https://8.8.8.8/dns-query`). Forced by two
   LAN realities: Technitium poisons the authoritative-NS lookup for the
   local zone, and the Vodafone hub drops outbound port 53 wholesale.
   See the lesson doc — this cost most of the deploy time.

## What I rejected

- **Traefik's built-in ACME (certificatesResolvers)** — keeps the cert
  in a local `acme.json` instead of a Secret, doesn't survive pod
  replacement without persistence, and can't be shared or inspected like
  a normal k8s object. cert-manager is the standard primitive and the
  cluster already runs its CRD exclusions in ArgoCD.
- **Cloudflare Origin CA certs** — only trusted by Cloudflare's edge,
  not by browsers, so they fix nothing for the LAN path.
- **Per-Ingress annotations / `tls:` sections** — N services × ceremony,
  versus one TLSStore. Rejected on maintenance grounds.
- **Pushing LAN traffic back through Cloudflare** (dropping split-horizon)
  — defeats the point of keeping LAN traffic local, and uploads >100MB
  would hit the tunnel cap from inside the house (ADR 006).

## Consequences

- LAN HTTPS to any `*.henrydowd.dev` host is now browser-valid; `git push`
  works without `http.sslVerify=false`.
- The Collabora `dnsPolicy: None` hairpin is gone — it was already
  silently broken by the router's port-53 block; WOPI reachback now goes
  through normal cluster DNS → Technitium → Traefik and sees the valid
  wildcard.
- `*.lan` hostnames still get the wildcard cert (mismatch warning) —
  unchanged from before, the `.lan` names are HTTP-mostly convenience
  aliases. Accepted; fixing it would mean a private CA for `.lan`.
- Renewal is automatic (cert-manager renews at 2/3 lifetime). If renewal
  breaks, the cert expires in ≤90 days — worth a future alert on
  `certmanager_certificate_expiration_timestamp_seconds`.
- Rebuild path: everything is in git (cert-manager app, config app,
  SealedSecret) — but the SealedSecret needs the sealed-secrets master
  key restored first, same as every other secret. ACME account keys are
  regenerated harmlessly on a fresh cluster.

## Related

- docs/lessons/networking/certmanager-dns01-split-horizon.md — the two
  DNS layers that blocked first issuance
- ADR 006 — the tunnel upload cap that makes split-horizon worth keeping
