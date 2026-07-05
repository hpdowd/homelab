# Incident: dowd-ie Certificate lived in the wrong namespace, secure.dowd.ie silently served the henrydowd.dev cert

## Date
2026-07-05

## Time lost
~30min. No user-facing outage in practice — file-parser is behind Cloudflare
Access and reached mostly via the tunnel, where Cloudflare's edge cert is what
browsers actually see — but LAN clients hitting `secure.dowd.ie` directly via
Technitium would get a certificate name mismatch.

## Status
Resolved.

## Context
- **System / component:** `dowd-ie` cert-manager `Certificate`, consumed by
  `file-parser`'s `Ingress` (`k8s/apps/file-parser/ingress.yaml`) for host
  `secure.dowd.ie`.
- **Scope:** only `secure.dowd.ie`. `secure.henrydowd.dev` and every other
  `*.henrydowd.dev` host were unaffected (served correctly by the Traefik
  `TLSStore` default cert).
- **State before:** the cert had been live since 2026-07-01 (commit adding
  `dowd-ie-cert.yaml`), issued successfully by cert-manager the whole time.

## Symptoms
`cert-manager` reported everything healthy — `Certificate` Ready, secret
present, valid Let's Encrypt cert with the right SANs. But an SNI probe
against Traefik's LB IP for `secure.dowd.ie` returned the *henrydowd.dev*
cert, not dowd.ie's:

```text
$ openssl s_client -connect 192.168.1.200:443 -servername secure.dowd.ie | openssl x509 -noout -subject
subject=CN=henrydowd.dev
```

Traefik logs were quietly repeating this every resync:
```text
Error configuring TLS error="secret file-parser/dowd-ie-tls does not exist" ingress=file-parser namespace=file-parser providerName=kubernetes
```

## Investigation
- `kubectl get certificate -A` showed both `henrydowd-dev` and `dowd-ie`
  `Ready=True` — looked completely fine from cert-manager's side.
- Cross-checked live behavior instead of trusting the manifests: pulled the
  `dowd-ie-tls` secret from the `traefik` namespace and confirmed via
  `openssl x509` it was a real, unexpired, correctly-SAN'd cert.
- Then did an actual TLS handshake (`openssl s_client -servername
  secure.dowd.ie`) against the Traefik LB — got the *wrong* cert back. That's
  what surfaced it; the Certificate/secret being healthy said nothing about
  whether Traefik could actually see it.
- `kubectl logs deploy/traefik` had been logging the exact reason on every
  resync the whole time — checking Traefik's own logs would have caught this
  immediately without any of the above.

## Root cause
Copy-paste from the wrong pattern. `henrydowd-dev-cert.yaml`'s comment
explains it lives in the `traefik` namespace so the Traefik `TLSStore` CRD
(also in `traefik` ns) can reference its secret — Traefik CRDs like
`TLSStore.spec.defaultCertificate` resolve secrets in the CRD's own
namespace. `dowd-ie-cert.yaml` copied that placement "for the same
cross-namespace-secret reason as the other one" — but `dowd-ie` was never
wired into the TLSStore. It's consumed by a plain Kubernetes `Ingress`
(`file-parser`'s), and for **core `Ingress` objects, `spec.tls[].secretName`
only resolves against secrets in the Ingress's own namespace** — there is no
cross-namespace secret ref for standard Ingress TLS, full stop. Since the
Certificate wrote its secret to `traefik/dowd-ie-tls` instead of
`file-parser/dowd-ie-tls`, Traefik's kubernetes Ingress provider never found
it and silently fell back to the default TLSStore cert for that SNI.

## Fix
Moved the `Certificate` to the `file-parser` namespace, matching where its
Ingress actually needs the secret:

```diff
 metadata:
   name: dowd-ie
-  namespace: traefik
+  namespace: file-parser
```

ArgoCD (auto-sync, prune: true) created the new `file-parser/dowd-ie`
Certificate and pruned the old `traefik/dowd-ie` one; cert-manager's
ownerReference on the old secret meant it got garbage-collected along with
it, and cert-manager issued a fresh cert in the new namespace via the same
`letsencrypt-prod` ClusterIssuer / Cloudflare DNS-01 solver.

## Verification
```bash
kubectl get certificate -n file-parser dowd-ie   # Ready=True, new secret
echo | openssl s_client -connect 192.168.1.200:443 -servername secure.dowd.ie \
  | openssl x509 -noout -subject -ext subjectAltName
# subject=CN=dowd.ie, SAN: DNS:*.dowd.ie, DNS:dowd.ie
kubectl logs -n traefik deploy/traefik --tail=50 | grep dowd   # no more errors
```

## Prevention
- **A healthy `Certificate`/secret only proves cert-manager did its job — it
  proves nothing about whether the consumer (Traefik) can see the secret.**
  When wiring a new TLS secret into an Ingress, verify with an actual TLS
  handshake against the right SNI, not just `kubectl get certificate`.
- **Core `Ingress` TLS secrets are same-namespace only, always.** Cross-namespace
  secret refs only exist for Traefik's own CRDs (`TLSStore`, and only because
  it's cluster-scoped-by-convention with a fixed namespace) — don't assume the
  same rule for anything using a plain `Ingress`.
- Traefik already logs this exact failure clearly and continuously
  (`Error configuring TLS ... secret <ns>/<name> does not exist`) — worth a
  standing reminder to check `kubectl logs deploy/traefik` when a
  newly-wired per-Ingress cert doesn't seem to be taking effect.

## Related
- `k8s/infrastructure/cert-manager-config/dowd-ie-cert.yaml`
- `k8s/infrastructure/cert-manager-config/tlsstore.yaml` — the TLSStore this
  cert is deliberately *not* part of.
- `k8s/apps/file-parser/ingress.yaml` — the consuming Ingress.
