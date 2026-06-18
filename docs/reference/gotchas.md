# Gotchas

The sharp edges of this setup. Most were learned the hard way, and each
entry links to the lesson or runbook with the full story. If one of
these looks wrong, read the linked doc before fixing it.

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

**selfHeal fights anything that scales a managed workload.** A job that
scales a Deployment to 0 (like the Gitea backup) gets reverted within
seconds — the backup then runs against a live app while still reporting
success. Anything that scales a managed Deployment needs
`ignoreDifferences` on `/spec/replicas` plus the
`RespectIgnoreDifferences=true` sync option in that app. See
`docs/lessons/k8s/argocd-selfheal-backup-race.md`.

**ArgoCD's repo fetch rides the LAN's DNS.** The repo URL is the public
`git.henrydowd.dev`, so what ArgoCD actually reaches depends on what the
cluster's upstream resolver answers: public DNS → Cloudflare (valid
cert), Technitium → Traefik (self-signed → every git-sourced app goes
`Unknown / ComparisonError` at once). Bit on 2026-06-12 when the LAN's
default DNS moved to Technitium; the repo connection is now registered
with `insecure: "true"` (same posture as `argocd login --insecure`).
Since 2026-06-12 Traefik serves a real Let's Encrypt wildcard (ADR 007),
so the flag is no longer load-bearing day-to-day — but it **stays**:
during a rebuild ArgoCD must fetch the repo *before* cert-manager exists,
when Traefik is back on its self-signed default.
Symptom to remember: *all* git-sourced apps flip Unknown simultaneously
while Helm-sourced ones stay Synced.

**The repo credential secret is bootstrap-only, not in git.** ArgoCD's
access to the private repo lives in a `repo-*` Secret in the argocd
namespace, created by hand. A rebuilt cluster needs it re-registered
(rebuild runbook step 6) before root-app can fetch anything.

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
- **TLS on the LAN path is one default cert, not per-Ingress config.**
  The `default` TLSStore in the traefik namespace points `websecure` at
  the cert-manager wildcard (`henrydowd-dev-tls`). New services need no
  `tls:` blocks or annotations — they get valid HTTPS for free. Don't
  add per-Ingress TLS config; one secret covers `*.henrydowd.dev`.
  (`*.lan` names still get the wildcard → mismatch warning; accepted,
  see ADR 007.)

## TLS / cert-manager

- The wildcard cert renews automatically (~2/3 of its 90-day life). If
  a Certificate ever sticks at `Ready: False`, read the **Challenge's
  `status.reason`** first — it names the exact DNS lookup that failed.
- The DNS-01 self-check runs over **DoH** (`--dns01-recursive-nameservers`
  in `k8s/infrastructure/cert-manager.yaml`). Two LAN facts force this
  and neither is going away: Technitium is authoritative for the local
  `henrydowd.dev` zone (its NS answer `technitium.` is unresolvable
  in-cluster), and the Vodafone hub drops outbound port 53 to public
  resolvers entirely. See
  `docs/lessons/networking/certmanager-dns01-split-horizon.md`.
- Corollary: **never hand a pod public resolvers via `dnsConfig`** —
  plain :53 to 1.1.1.1/8.8.8.8 times out from this LAN. That's what
  silently broke Collabora's interim WOPI hairpin.
- The Cloudflare token (Zone:Read + DNS:Edit) is a SealedSecret in the
  cert-manager namespace — same master-key dependency as everything
  else sealed.

## Service-link env vars

kubelet injects docker-link-style vars (`<SVC>_PORT=tcp://ip:port`) for
every Service in the namespace. An app that reads an env var named like
your Service crash-loops on boot — Immich's `REDIS_PORT` met the `redis`
Service this way. `enableServiceLinks: false` on the pod spec turns the
whole legacy mechanism off.

## Gitea Actions / DinD

- **The dind sidecar gives the *runner* a Docker daemon, not the job
  steps.** A job container (`catthehacker/ubuntu`) has no
  `/var/run/docker.sock` and `DOCKER_HOST` isn't propagated, so
  `docker build`/`push` fail with `docker.sock: no such file or
  directory` even though `docker login` succeeds (login only writes a
  config and hits the network). The runner was only ever wired for
  daemonless jobs (kubeconform); image builds go to GitHub-hosted
  runners via the push-mirror. Don't assume a job can `docker build`
  just because a dind sidecar exists. See
  `docs/lessons/k8s/act-runner-no-docker-daemon.md`.
- **Match the inner docker bridge MTU to the pod network (1450), or
  internet-bound TLS from jobs black-holes.** The pod's flannel `eth0` is
  MTU 1450; docker bridges default to 1500, and act_runner's per-job
  networks inherit that. Job steps reaching the internet (e.g. `curl
  github.com`) hang ~2.5min then `curl: (35) ... Connection reset by peer`
  — large DF packets are silently dropped. `actions/checkout` still works
  (internal Gitea, small packets), which masks it. Fix: a `daemon.json` in
  the dind sidecar with `"mtu": 1450` **and** `default-network-opts` for
  the bridge driver (the latter needs docker ≥ 26; covers act-created
  networks). Generalises to **any** privileged-docker workload here. See
  `docs/lessons/k8s/act-runner-dind-mtu-oom.md`.
- **Give Go workloads `GOMEMLIMIT`, not just a cgroup limit.** act_runner
  is a Go binary; its GC grows the heap toward the container limit without
  knowing the cap, so it OOMKills (exit 137) under load even with a ~10Mi
  idle working set — bit at both 192Mi and 384Mi. Set `GOMEMLIMIT` below
  the hard limit (700MiB under a 768Mi cap) so the runtime GCs first. Same
  lesson doc.

## Longhorn

- RWO volumes mean `strategy: Recreate` on every Deployment that mounts
  one — RollingUpdate deadlocks waiting for the PVC to detach.
- A CronJob sharing a RWO PVC with a live pod needs `podAffinity` to
  co-schedule on the same node, or it hits Multi-Attach errors.
- Replica count is **1, worker only** (single usable storage node — see
  ADR 005's RAM/disk reasoning). Two places control it and both have
  bitten: the `default-replica-count` *setting*, and the
  `numberOfReplicas` *parameter* baked into the `longhorn` StorageClass
  (which wins for every dynamically provisioned PVC — the first Immich
  volumes came up degraded at 3 replicas hours after the setting was
  fixed). The SC is regenerated from the `longhorn-storageclass`
  ConfigMap; fix it there, commands in cluster-rebuild.md step 3.
  Verify after any Longhorn reinstall *and after adding any service*:
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
- An alert on a metric nobody scrapes never fires. Pair the important
  ones with an `absent()` guard (see `LonghornMetricsAbsent` in
  `homelab-rules.yaml`).
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
