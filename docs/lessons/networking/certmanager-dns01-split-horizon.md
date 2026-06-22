# Incident: cert-manager DNS-01 self-check stuck, split-horizon DNS, then a router that eats port 53

## Date
2026-06-12

## Time lost
~1h (caught on first deploy of cert-manager, not in production use, but it
also exposed that Collabora's WOPI reachback had been silently broken)

## Status
Resolved

## Context
- **System / component:** cert-manager (new install, `cert-manager` ns), Technitium LXC 100, Vodafone Ultra 7 Hub
- **Scope:** first issuance of the `*.henrydowd.dev` wildcard Certificate; investigation revealed LAN-wide outbound port-53 blocking that had already broken Collabora's interim DNS hairpin
- **State before:** cert-manager freshly deployed for the LAN TLS fix; ClusterIssuers Ready, ACME account registered, TXT records successfully created in Cloudflare

## Symptoms
- Both DNS-01 challenges (`henrydowd.dev` apex + wildcard) stuck `pending`
  with `Presented: true`; Certificate never left
  `Issuing certificate as Secret does not exist`.
- First smoking gun (challenge status / controller logs):
  ```text
  Waiting for DNS-01 challenge propagation: dial udp: lookup technitium. on 10.43.0.10:53: no such host
  ```
- After pointing the self-check at public resolvers on :53, a second one:
  ```text
  propagation check failed: dial tcp 1.0.0.1:53: i/o timeout
  ```

## Investigation
- TXT records were *created fine*, the Cloudflare token worked (zone read
  + dns_records edit verified by hand). Not a credentials problem.
- The first error names `technitium.` as a hostname cert-manager tried to
  dial. That's not a Cloudflare nameserver; it's the NS record of
  Technitium's **local** `henrydowd.dev` zone. → layer 1 confirmed.
- After fixing layer 1 with `--dns01-recursive-nameservers=1.1.1.1:53,...`:
  i/o timeouts. Tested from the workstation (same LAN): `dig @1.1.1.1`,
  `@1.0.0.1`, `@8.8.8.8` all time out, UDP **and** TCP; so the block is
  LAN-wide at the router, not a cluster egress problem. DoH
  (`https://1.1.1.1/dns-query`) goes through fine and showed the challenge
  TXT already propagated. → layer 2 confirmed.
- Side discovery: Collabora's interim WOPI hairpin (`dnsPolicy: None`,
  nameservers 1.1.1.1/1.0.0.1) depends on exactly what the router blocks,
  `getent hosts nextcloud.henrydowd.dev` from the collabora pod fails with
  "not found". Document editing was broken and nothing alerted.

## Root cause
Two independent layers, same theme, *in-cluster consumers that need the
public view of henrydowd.dev can't get it*:

1. **Split-horizon DNS poisons cert-manager's self-check.** Before asking
   Let's Encrypt to validate, cert-manager resolves the zone's
   authoritative NS and queries it for the `_acme-challenge` TXT. That
   lookup goes pod → CoreDNS → node resolver → **Technitium**, which is
   authoritative for the local zone and answers with its own NS record:
   the bare name `technitium.`, unresolvable in-cluster. The check loops
   forever. (Even if it resolved, Technitium would never serve the TXT,
   the real record lives in Cloudflare.)
2. **The Vodafone hub silently drops outbound port 53** to external
   resolvers (Cloudflare and Google, UDP and TCP). Any "just use 1.1.1.1"
   workaround on this LAN is dead on arrival. Technitium itself only works
   because it forwards upstream over an encrypted transport, not plain 53.

## Fix
Self-check via public resolvers **over DoH** (supported by
`--dns01-recursive-nameservers` since cert-manager v1.12). In
`k8s/infrastructure/cert-manager.yaml` helm values:

```yaml
extraArgs:
  - --dns01-recursive-nameservers-only
  - --dns01-recursive-nameservers=https://1.1.1.1/dns-query,https://8.8.8.8/dns-query
```

(commits `0351dee` → `2d48716`)

## Verification
```bash
kubectl -n traefik get certificate henrydowd-dev   # READY True
echo | openssl s_client -connect 192.168.1.200:443 -servername immich.henrydowd.dev 2>/dev/null | openssl x509 -noout -subject -issuer
# subject=CN=henrydowd.dev  issuer=...Let's Encrypt...
```

## Prevention
- Flags live in the committed helm values; a rebuild gets them for free.
  If a future Certificate sticks at `pending`, read the Challenge's
  `status.reason` first; it names the exact lookup that failed.
- General rule for this LAN, now twice-proven: **plain DNS to public
  resolvers does not work from anywhere on this network.** Anything that
  needs the public view must use DoH/DoT or go through Technitium's
  encrypted upstream. Don't hand pods `nameservers: [1.1.1.1]`; that's
  what silently killed Collabora's hairpin.
- The hairpin itself is gone: with the wildcard cert on Traefik, Collabora
  resolves `nextcloud.henrydowd.dev` via normal cluster DNS → Technitium →
  Traefik, and the cert it sees is valid.

## Related
- ADR: docs/adr/007-certmanager-wildcard-tls.md
- Other lessons: docs/lessons/networking/vodafone-hub-ghost-portforward.md (same router, same "silently does its own thing" genre) · docs/lessons/networking/proxmox-502-selfsigned-tunnel.md
