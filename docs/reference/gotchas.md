# Gotchas

The sharp edges of this specific setup, collected in one place. Most of
these were learned the hard way — each links to the lesson or runbook
with the full story. If something here seems wrong, read the linked doc
before "fixing" it.

## ArgoCD

**The EndpointSlice exclusion patch must be reapplied after any cluster
rebuild.** ArgoCD's default `resource.exclusions` filter out
EndpointSlices, so the hand-written slices that point Traefik at AMP and
Proxmox silently never sync — "no available server" with no obvious
cause. The patch (and the required `argocd-server` restart) is step 6 of
`docs/runbooks/cluster-rebuild.md`.

**root-app discovers `k8s/apps/*.yaml` non-recursively.** A subdirectory
with no matching top-level `<name>.yaml` Application is silently
orphaned — nothing syncs, nothing errors. See
`docs/lessons/k8s/grafana-monitoring-sync-cascade.md`.

**Inline Helm values drift silently.** An indent slip, duplicate
top-level key (YAML last-wins), or typo'd key in a
`spec.source.helm.values: |` block doesn't crash anything — the app goes
`Unknown`/`ComparisonError` or silently ignores the key while live pods
keep running the old spec. After editing inline values check
`argocd app get <app>`, not just the pods; validate non-trivial edits
with `helm template` against the pinned chart version. See
`docs/lessons/k8s/argocd-comparisonerror-silent-values.md`.

## Traefik / ingress

- `ingressClassName: traefik` on every Ingress — classless ingresses
  only work via the default-class fallback, and a missing class is
  silently 404.
- **Never pin `router.entrypoints: websecure`.** cloudflared hits
  Traefik over plain HTTP on `web`; a websecure-only router 404s every
  public hit. Applies to every TLS-behind-Cloudflare service.
- A missing or misnamed Middleware reference drops the whole router
  silently → 404.
- Diagnose Traefik vs tunnel:
  `curl -H "Host: <hostname>" http://192.168.1.200/ -I`

## Longhorn

- RWO volumes mean `strategy: Recreate` on every Deployment that mounts
  one — RollingUpdate deadlocks waiting for the PVC to detach.
- A CronJob sharing a RWO PVC with a live pod needs `podAffinity` to
  co-schedule on the same node, or it hits Multi-Attach errors.
- Replica count is **1, worker only** (single usable storage node — see
  ADR 005's RAM/disk reasoning). If `default-replica-count` ever drifts
  back to 3, every volume sits permanently `degraded` and replicas land
  on the control node's OS disk. Verify after any Longhorn reinstall:
  `kubectl -n longhorn-system get volumes.longhorn.io` — every volume
  should say `healthy`, not `degraded`.

## restic / backups

- `RESTIC_REPOSITORY` must start with `s3:https://` — without the `s3:`
  prefix restic "succeeds" against the pod's ephemeral disk and the
  bucket stays empty.
- `RESTIC_PASSWORD` exists only in the password manager. Losing it is
  permanent data loss.
- The B2 bucket lifecycle must be "keep only the last version", or
  `restic forget --prune` never actually frees space.

## Sealed Secrets

The controller's master key must be restored **before** ArgoCD syncs
anything — a fresh controller generates a new key and every SealedSecret
in the repo fails to decrypt. `kubeseal --fetch-cert` should match the
backed-up cert. See `docs/runbooks/cluster-rebuild.md` step 4.

## Nextcloud identity

`instanceid`/`secret`/`passwordsalt` in `config.php` must match the
imported DB — they're in the `nextcloud-secrets` SealedSecret. Restore
the SealedSecret before the pod first starts, not after, or sessions and
encrypted fields break.

## WireGuard LXC (101)

Never `pct enter` it (or SSH into it through the tunnel) while the VPN
is active — network-namespace conflict freezes the container in D-state
and only a host hard-reboot recovers. Use a LAN session or the host
console with the VPN disconnected. See
`docs/lessons/infra/wireguard-lxc-dstate-freeze.md`.

## Alpine LXCs: busybox crond doesn't notice appended crontabs

busybox crond only re-reads `/etc/crontabs` when the *directory* mtime
changes; appending a line to `/etc/crontabs/root` doesn't touch it, so
the new entry silently never runs. `rc-service crond restart` after
editing. (Bit the cloudflare-ddns move to LXC 101.)

## Collabora securityContext

`appArmorProfile: {type: Unconfined}` must be the securityContext
**field** — the deprecated annotation silently doesn't apply on
k3s ≥ 1.30, the default cri-containerd profile denies `mount(2)`, and
CODE falls back to copying the whole LO tree per kit jail (~6ms → ~48s).
The capability list feeds *file capabilities* on
`coolmount`/`coolforkit-caps`; pid 1 showing `CapEff=0` is the healthy
state — don't "fix" it. See
`docs/lessons/k8s/collabora-slow-load-wordbook.md`.

## Monitoring

- Use `VMRule`/`VMServiceScrape` (VictoriaMetrics operator), **not**
  `PrometheusRule`/`ServiceMonitor` — one invalid CRD kind fails the
  whole Application's sync batch.
- An alert on a metric nobody scrapes never fires. Pair
  domain-critical alerts with an `absent()` guard (see
  `LonghornMetricsAbsent` in `homelab-rules.yaml`).
- local-path PVCs survive namespace deletion. When reinstalling a Helm
  app after a failed deploy, delete the PVCs explicitly — a reused
  Grafana PVC with a corrupt SQLite crashed every reinstall. See
  `docs/lessons/k8s/grafana-pvc-corruption.md`.

## Stuck namespace Terminating (vm-operator pattern)

vm-operator sets `apps.victoriametrics.com/finalizer` on its CRs; if the
operator is gone first, the namespace hangs forever. Force-clear:

```bash
for crd in vmagents vmalertmanagers vmalerts vmsingles; do
  kubectl get $crd -n monitoring -o name 2>/dev/null | \
    xargs -I{} kubectl patch {} -n monitoring \
      --type=merge -p '{"metadata":{"finalizers":null}}'
done
kubectl get namespace monitoring -o json | \
  python3 -c "import sys,json; ns=json.load(sys.stdin); ns['spec']['finalizers']=[]; print(json.dumps(ns))" | \
  kubectl replace --raw /api/v1/namespaces/monitoring/finalize -f -
```

## Helm charts

Verify versions with `helm search repo <chart>` before pinning — never
trust a version from memory. All chart `targetRevision`s in this repo
are pinned exactly; bumps are deliberate commits.
