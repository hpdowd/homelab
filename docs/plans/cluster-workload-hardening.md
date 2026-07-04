# Cluster workload hardening: per-image securityContext + namespace NetworkPolicy isolation

*Drafted 2026-07-03. **Executed 2026-07-03** — shipped as
`docs/adr/011-workload-securitycontext-networkpolicy.md`. Outcome vs. this plan:
the securityContext baseline landed on 9 workloads; NetworkPolicies landed on 5
namespaces (portfolio, kiwix, collabora, file-parser, gitea). Two carve-outs the
plan didn't foresee — `immich-ml` stays at default (its ONNX worker hangs under
the restricted profile) and the `immich`/`nextcloud` netpols were reverted (a
kube-router fresh-pod race broke nextcloud-cron; post-mortem in
`docs/lessons/k8s/netpol-fresh-pod-race.md`). The design and rollout order below
are kept as the record.*

Companion to ADR 010 (which removed the privileged act-runner). Two independent
mechanisms, rolled out together as one pass: a securityContext baseline on every
app workload, and default-deny-ingress NetworkPolicies per app namespace.

## Part A — securityContext baseline

**Model: drop every Linux capability, add back only what each image's entrypoint
actually needs.** Deliberately *not* a blanket `runAsNonRoot` — several images
start as root by design and drop privileges themselves (Postgres/Gitea via
gosu/su-exec, Nextcloud apache), so forcing non-root breaks the entrypoint. The
authoritative per-image cap set lives in each deployment's `securityContext`
comment; the postures:

| Posture | Workloads | Why |
|---|---|---|
| Full lockdown — non-root + `readOnlyRootFilesystem` + drop ALL | portfolio, both redis/valkey | no secrets / throwaway state, nothing to write |
| Non-root, drop ALL (image already non-root) | kiwix | runs as its own user; init stays root to chmod the volume |
| Capless root, drop ALL | immich server + ml | root-owned library PVC, but no caps needed |
| Root → drop-priv, keep setuid caps | postgres ×2, gitea, nextcloud | gosu/su-exec/apache need CHOWN + SETUID/SETGID etc. to drop; nextcloud also NET_BIND_SERVICE for :80 |

All get `seccompProfile: RuntimeDefault` and `allowPrivilegeEscalation: false`
(the latter still permits privilege *dropping*).

**Collabora is deliberately exempt** — it keeps `SYS_ADMIN` / `SYS_CHROOT` /
`MKNOD` + AppArmor `Unconfined`, load-bearing for its per-document jails (see the
collabora gotcha + slow-load lessons). Hardening it re-breaks the jails.

### Rejected
- **Blanket `runAsNonRoot` everywhere** — breaks every root-then-drop entrypoint
  (Postgres, Gitea, Nextcloud); the per-image add-back exists precisely to avoid this.
- **PodSecurity Standards admission (`restricted`)** — too blunt: it would reject
  Collabora and the root-then-drop images cluster-wide and can't express "capless
  root is fine here". Per-pod securityContext is the right granularity for a
  heterogeneous app set.
- **Leaving it** — file-parser was already hardened; extending the same posture to
  the rest is defense-in-depth at near-zero ongoing cost (declarative,
  self-documenting, fails loud at rollout).

## Part B — namespace NetworkPolicy isolation

**Model: default-deny ingress per app namespace, then allow (1) same-namespace
traffic and (2) the web/probe ports from the pod CIDR.** DB/cache ports stay
same-namespace only, so a compromised public-facing pod can't reach another
namespace's Postgres/Redis directly. The cross-namespace HTTP that must keep
working (Traefik → apps, Collabora ↔ Nextcloud WOPI, VictoriaMetrics scrapes)
rides the web-port allow from the pod CIDR.

**file-parser gets the strict treatment** — the cluster's most sensitive
workload, so deny-by-default in *both* directions: ingress only on its HTTP port,
egress only to DNS and the single endpoint it must reach. A compromise elsewhere
can't reach it; a compromise of it can't pivot out.

### k3s specifics that shaped the rules
- **DNS egress must select the `kube-system` namespace, not the CoreDNS Service
  IP** — the ClusterIP is DNAT'd to the CoreDNS pod before the policy is
  evaluated, so an `ipBlock` on the service IP silently fails.
- **Health probes** come from the kubelet; allow the pod CIDR *and* the node IPs
  so a probe sourced from a node's LAN address still passes.
- k3s runs the kube-router netpol controller in-process (no separate pod), active
  unless started with `--disable-network-policy`. Verify enforcement empirically
  after rollout: a pod in another namespace should fail to reach a DB, while
  Traefik still serves the app.

### Rejected
- **Full default-deny-all (ingress + egress everywhere)** — would block DNS,
  probes, and cross-namespace WOPI/scrapes; a large per-app allow-list burden for
  marginal gain over the web-port model. file-parser is the one place the strict
  both-directions treatment is worth it.
- **No policies (flat network)** — the status quo; any compromised pod reaches
  every other namespace's data plane. Unacceptable given file-parser.

## Rollout (phased; commit + watch each)
1. **portfolio, kiwix** — trivial, stateless.
2. **file-parser NetworkPolicy** — confirm it still serves.
3. **immich + nextcloud** (server / ml / redis / web) + their NetworkPolicies.
4. **the two Postgres** — riskiest (the cap set must be exact); watch for CrashLoop.

Per phase: `kubectl -n <ns> get pods -w`, confirm Ready + clean logs. Rollback is
`git revert` (ArgoCD re-syncs) or `kubectl rollout undo`.

Watch-items:
- the immich **vectorchord** Postgres (custom image — least-certain cap set);
  revert that one file if it CrashLoops.
- portfolio **`readOnlyRootFilesystem`** — add an emptyDir `/tmp` if the binary
  writes there.
- NetworkPolicies not blocking **probes** (pods stay Ready) or **WOPI** (open a
  Collabora document to confirm the cross-namespace call still works).

## On completion
- Produce an ADR from the decision + rejected alternatives above.
- Move any k3s netpol specific that actually bit into `reference/gotchas.md`.
