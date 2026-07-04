# ADR 011: Workload securityContext baseline + namespace NetworkPolicy isolation

**Status:** Accepted (with two documented carve-outs — see Consequences)
**Date:** 2026-07-03
**Companion to:** ADR 010 (which removed the last privileged container)

## What problem this solves

After ADR 010 the cluster had no privileged CI container, but every app
workload *except* `file-parser` still ran the way its image shipped: as root,
with the full Linux capability set, a writable root filesystem, and no seccomp
profile. The network was flat — any pod could open a TCP connection to any
other namespace's Postgres or Redis directly, including into the `file-parser`
hardened app.

Two concrete exposures followed. A container-RCE in an internet-facing app
(`nextcloud`, `immich`) landed as capable root — the strongest possible base
for a breakout attempt. And a single compromised pod anywhere could reach every
database and the sensitive app across the pod network with nothing in the way.
`file-parser` was already hardened at the pod level and behind Cloudflare Access
at the edge; nothing else was.

## What I picked

Two independent mechanisms, rolled out as one phased pass (portfolio/kiwix →
file-parser netpol → immich → nextcloud/collabora → the two Postgres → gitea),
each phase committed separately and watched to Ready before the next.

**A. A per-image securityContext baseline — drop every capability, add back
only what each image's entrypoint actually needs.** Deliberately *not* a blanket
`runAsNonRoot`: several images start as root by design and drop privileges
themselves, so forcing non-root breaks the entrypoint. The postures:

| Posture | Workloads |
|---|---|
| Full lockdown — non-root + `readOnlyRootFilesystem` + drop ALL | portfolio, both redis/valkey |
| Non-root (image already is) + drop ALL | kiwix |
| Capless root — drop ALL, no caps back | immich-server |
| Root → drop-priv, keep setuid caps (`CHOWN,DAC_OVERRIDE,FOWNER,SETGID,SETUID`; nextcloud also `NET_BIND_SERVICE` for :80) | postgres ×2, gitea, nextcloud apache |

All get `seccompProfile: RuntimeDefault` and `allowPrivilegeEscalation: false`
(which still permits privilege *dropping*). The authoritative per-image cap set
and its reasoning live in each deployment's `securityContext` comment.

**B. Default-deny-ingress NetworkPolicies per app namespace** — allow
same-namespace traffic and the web/probe ports from the pod CIDR; DB/cache ports
stay same-namespace only. `file-parser` gets the strict treatment: deny-by-default
in *both* directions — ingress only on `:8000` in-cluster, egress only to DNS and
the printer — so a compromise elsewhere can't reach it and a compromise of it
can't pivot out.

Landed: securityContext on **9 workloads**; NetworkPolicies on **5 namespaces**
(portfolio, kiwix, collabora, file-parser, gitea).

## What I rejected

- **Blanket `runAsNonRoot` everywhere** — breaks every root-then-drop entrypoint
  (Postgres, Gitea, Nextcloud apache); the per-image add-back exists precisely to
  avoid this.
- **PodSecurity Standards admission (`restricted`)** — too blunt for a
  heterogeneous set: it would reject Collabora and the capless-root images
  cluster-wide and can't express "capless root is fine here". Per-pod
  securityContext is the right granularity.
- **Leaving the network flat** — the status quo; any compromised pod reaches
  every namespace's data plane. Unacceptable given `file-parser`.
- **Full default-deny (ingress + egress) on every namespace** — would block DNS,
  probes, and cross-namespace WOPI/scrapes for a large per-app allow-list burden;
  `file-parser` is the one place the strict both-directions treatment earns its keep.

## Consequences

- **`file-parser` is isolated both directions, verified empirically.** From
  inside the pod: DNS resolves and the printer (`192.168.1.40:631`) is reachable,
  while the kube-apiserver and the internet are refused. Ingress is `:8000`,
  in-cluster only. This is the highest-value isolation in the pass and it stands.
- **Collabora stays exempt from the securityContext baseline** — its
  `SYS_ADMIN`/`SYS_CHROOT`/`MKNOD` + AppArmor `Unconfined` are load-bearing for
  its per-document jails (see gotchas.md). Network-isolated instead (ingress netpol).

### Carve-out 1 — `immich-ml` left at default securityContext

Under the restricted profile its ONNX/uvicorn worker hangs at ~0 CPU and never
finishes startup — `/ping` times out even from *inside* the pod, no
"application startup complete" ever logs. `immich-server` took the identical
pod-level seccomp + cap set fine, so it is specific to the ML worker. Reverted to
default and treated as an exemption like Collabora; the security value of
hardening an internal-only ML service (it faces `immich-server`, not the edge) is
marginal. Worth a later isolation attempt (seccomp-only, to identify whether
seccomp or the cap drop is the trigger), out of the critical path.

### Carve-out 2 — `immich` + `nextcloud` NetworkPolicies reverted

The default-deny-ingress + same-namespace-`podSelector` pattern **races
kube-router's per-pod source registration**. A fresh, short-lived pod that
connects to a same-namespace service in its first few seconds is denied until
kube-router adds its IP to the namespace source-set (measured: blocked at t=0,
allowed at t=14s). That broke `nextcloud-cron` (every-5-min `php cron.php`,
connects immediately) and would put the nightly `immich`/`nextcloud` `pg_dump`
backups at risk (immich's dump runs once, no retry). I won't ship a control whose
safety rides on an incidental `apk`-vs-registration timing margin over the only
offsite DB backup — so their securityContext hardening stays, the two netpols
came off, and this is deferred to a wait-guarded redesign
(`until pg_isready; do sleep 2; done` before the cron/backup connects, then the
netpols return cleanly). The `gitea` netpol is safe and kept: its backup only
talks to the kube API + PVC, and the act-runner it fronts is long-lived. Full
mechanism and probe in the lesson below.

- **A CI policy gate is now worth adding** (conftest/kyverno in the host-executor
  lint job): assert "no privileged pods; every app container sets
  `allowPrivilegeEscalation:false`" so the baseline can't regress silently. Low
  effort, high longevity — tracked as follow-up.

## Related

- ADR 010 — removed the last privileged container; this extends defense-in-depth
  to the rest of the workloads.
- `docs/plans/cluster-workload-hardening.md` — the design + phased rollout order
  this executed (now marked complete).
- `docs/lessons/k8s/netpol-fresh-pod-race.md` — the kube-router fresh-pod race
  post-mortem (carve-out 2).
- `docs/reference/gotchas.md` — NetworkPolicy section (the race) + Collabora
  securityContext (the standing exemption).
