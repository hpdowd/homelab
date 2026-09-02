# Gotchas

The sharp edges of this setup. Most were learned the hard way, and each
entry links to the lesson or runbook with the full story. If one of
these looks wrong, read the linked doc before fixing it.

## ArgoCD

**The EndpointSlice exclusion patch must be reapplied after any cluster
rebuild.** ArgoCD's default `resource.exclusions` filter out
EndpointSlices, so the hand-written slices that point Traefik at AMP and
Proxmox silently never sync, "no available server" with no obvious
cause. The patch (and the required `argocd-server` restart) is step 6 of
`docs/runbooks/cluster-rebuild.md`.

**root-app discovers `k8s/apps/*.yaml` non-recursively.** A subdirectory
with no matching top-level `<name>.yaml` Application is silently
orphaned, nothing syncs, nothing errors. See
`docs/lessons/k8s/grafana-monitoring-sync-cascade.md`.

**Suspending auto-sync on one app is not enough — `root-app` manages the
Application objects too.** Patching `spec.syncPolicy.automated: null` on
`immich` was reverted by `root-app` within seconds, and `selfHeal` then
put a `scale --replicas=0` back within 3. To actually stop a workload for
maintenance, suspend `root-app` **first**, then the child app. Save the
originals before touching them and diff them back afterwards:

```bash
kubectl -n argocd get app <name> -o jsonpath='{.spec.syncPolicy}'   # save this
kubectl -n argocd patch app root-app --type=merge \
  -p '{"spec":{"syncPolicy":{"automated":null}}}'
```

An operator-owned resource needs its own brake as well: ArgoCD only
manages what is in git, so the VictoriaMetrics operator will rebuild a
`vmsingle` Deployment regardless. That one needs `spec.paused: true` on
the VMSingle CR.

**selfHeal fights anything that scales a managed workload.** A job that
scales a Deployment to 0 (like the Gitea backup) gets reverted within
seconds; the backup then runs against a live app while still reporting
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
so the flag is no longer load-bearing day-to-day, but it **stays**:
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
`spec.source.helm.values: |` block doesn't crash anything, the app goes
`Unknown`/`ComparisonError` or silently ignores the key while live pods
keep running the old spec. After editing inline values check
`argocd app get <app>`, not just the pods; validate non-trivial edits
with `helm template` against the pinned chart version. See
`docs/lessons/k8s/argocd-comparisonerror-silent-values.md`.

## Traefik / ingress

- `ingressClassName: traefik` on every Ingress, classless ingresses
  only work via the default-class fallback, and a missing class is
  silently 404.
- **Never pin `router.entrypoints: websecure`.** cloudflared hits
  Traefik over plain HTTP on `web`; a websecure-only router 404s every
  public hit. Applies to every TLS-behind-Cloudflare service.
- **An HTTPS-native backend with a `Secure` auth cookie (Proxmox) needs
  HTTPS on the LAN too, as a *second* IngressRoute.** PVE issues its
  auth cookie `Secure`, so a plain-HTTP browser drops it and login 401s
  right after it "succeeds". A CRD IngressRoute is served on `websecure`
  only with a `tls` block, and that block makes it TLS-only (404s the
  plain `web` tunnel); so it can't be one route. Proxmox runs two:
  `proxmox` (`web`, no tls, the tunnel, plus an http→https redirect on
  `proxmox.lan` so muscle-memory doesn't 401) and `proxmox-websecure`
  (`tls: {}`, LAN HTTPS). Plain Ingresses dodge this, the
  kubernetesIngress provider gives them websecure for free. See
  `docs/lessons/networking/proxmox-401-secure-cookie-plain-http.md`.
- A missing or misnamed Middleware reference drops the whole router
  silently → 404.
- **Authelia ForwardAuth needs `X-Forwarded-Proto: https` forced on the
  tunnel path, or every public hit 400s.** Authelia refuses to authorize a
  target with an http scheme (*"has an insecure scheme 'http', only the
  'https' and 'wss' schemes are supported so session cookies can be
  transmitted securely"*). cloudflared delivers to `web` over plain HTTP and
  Traefik rewrites `X-Forwarded-Proto` to the scheme it actually received on,
  because it trusts no upstream by default — so the LAN HTTPS path works and
  the tunnel 400s, which reads as a tunnel fault rather than an auth one.
  Chain `authelia-forceproto@kubernetescrd` **before**
  `authelia-forwardauth@kubernetescrd` on every gated host; middlewares apply
  left to right. Do NOT instead add the pod CIDR to
  `forwardedHeaders.trustedIPs`: that would also make Traefik honour a
  client-supplied `X-Forwarded-For`, which is what Authelia's `lan` network
  rule keys off, letting the internet claim LAN trust.
- **The Authelia portal's OWN Ingress needs forceproto too**, even though it is
  never gated — and the symptom lies to you. Enrolling TOTP or WebAuthn fails
  with *"Failed to generate One-Time Code. Please try again later"*, identically
  for both methods, which reads as a broken mail relay. It is not: the log says
  `Error occurred determining issuer, error="invalid X-Forwarded-Proto header
  value 'http'"` on `POST /api/user/session/elevation`. Serving the login page
  tolerates a wrong scheme; the endpoint that issues the enrolment code does
  not, and it never gets as far as sending mail. Retrying also trips Authelia's
  rate limiter (`delay≈280s`), which is in-memory — a pod restart clears it.
- Diagnose Traefik vs tunnel:
  `curl -H "Host: <hostname>" http://192.168.1.200/ -I`
- **TLS on the LAN path is one default cert, not per-Ingress config.**
  The `default` TLSStore in the traefik namespace points `websecure` at
  the cert-manager wildcard (`henrydowd-dev-tls`). New services need no
  `tls:` blocks or annotations; they get valid HTTPS for free. Don't
  add per-Ingress TLS config; one secret covers `*.henrydowd.dev`.
  (`*.lan` names still get the wildcard → mismatch warning; accepted,
  see ADR 007.)

## TLS / cert-manager

- The wildcard cert renews automatically (~2/3 of its 90-day life). If
  a Certificate ever sticks at `Ready: False`, read the **Challenge's
  `status.reason`** first; it names the exact DNS lookup that failed.
- The DNS-01 self-check runs over **DoH** (`--dns01-recursive-nameservers`
  in `k8s/infrastructure/cert-manager.yaml`). Two LAN facts force this
  and neither is going away: Technitium is authoritative for the local
  `henrydowd.dev` zone (its NS answer `technitium.` is unresolvable
  in-cluster), and the Vodafone hub drops outbound port 53 to public
  resolvers entirely. See
  `docs/lessons/networking/certmanager-dns01-split-horizon.md`.
- Corollary: **never hand a pod public resolvers via `dnsConfig`**,
  plain :53 to 1.1.1.1/8.8.8.8 times out from this LAN. That's what
  silently broke Collabora's interim WOPI hairpin.
- The Cloudflare token (Zone:Read + DNS:Edit) is a SealedSecret in the
  cert-manager namespace, same master-key dependency as everything
  else sealed.

## Service-link env vars

kubelet injects docker-link-style vars (`<SVC>_PORT=tcp://ip:port`) for
every Service in the namespace. An app that reads an env var named like
your Service crash-loops on boot, Immich's `REDIS_PORT` met the `redis`
Service this way. `enableServiceLinks: false` on the pod spec turns the
whole legacy mechanism off.

## NetworkPolicy (k3s / kube-router)

**Default-deny-ingress netpols race kube-router on fresh pods.** k3s
enforces NetworkPolicy with kube-router, which adds a new pod's IP to its
namespace source-set a few *seconds* after the pod starts. A short-lived
pod that connects to a same-namespace service inside that window isn't yet
matched by a `from: podSelector: {}` same-ns rule and gets **REJECTed**
("connection refused", not a hang). Bit `nextcloud-cron` (opens its
postgres connection at t≈0) during the ADR 011 hardening pass — measured
blocked at t=0, allowed at t=14s for the *same* pod. The `immich` /
`nextcloud` DB-isolation netpols were reverted for it while the
`securityContext` hardening stayed; the five netpols with no such
short-lived pod (`portfolio`, `kiwix`, `collabora`, `file-parser`,
`gitea`) are fine. Rules: only default-deny a namespace with no short-lived
same-ns pod hitting a protected port on startup; re-add these two only with
a `pg_isready` wait-guard on the cron/backup. And a *fast* "connection
refused" to a service you know is up is a netpol REJECT signature, not a
dead backend. See `docs/lessons/k8s/netpol-fresh-pod-race.md`.

## Gitea Actions / DinD

> **As of ADR 010 the runner uses the host executor — there is no DinD
> sidecar.** The docker-daemon and bridge-MTU entries below are historical
> (kept for the reasoning, and in case a privileged-docker workload ever
> returns); the `GOMEMLIMIT` entry still applies to the host-mode runner.

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
  github.com`) hang ~2.5min then `curl: (35) ... Connection reset by peer`,
  large DF packets are silently dropped. `actions/checkout` still works
  (internal Gitea, small packets), which masks it. Fix: a `daemon.json` in
  the dind sidecar with `"mtu": 1450` **and** `default-network-opts` for
  the bridge driver (the latter needs docker ≥ 26; covers act-created
  networks). Generalises to **any** privileged-docker workload here. See
  `docs/lessons/k8s/act-runner-dind-mtu-oom.md`.
- **Give Go workloads `GOMEMLIMIT`, not just a cgroup limit.** act_runner
  is a Go binary; its GC grows the heap toward the container limit without
  knowing the cap, so it OOMKills (exit 137) under load even with a ~10Mi
  idle working set, bit at both 192Mi and 384Mi. Set `GOMEMLIMIT` below
  the hard limit (700MiB under a 768Mi cap) so the runtime GCs first. Same
  lesson doc.

## Longhorn

- RWO volumes mean `strategy: Recreate` on every Deployment that mounts
  one, RollingUpdate deadlocks waiting for the PVC to detach.
- A CronJob sharing a RWO PVC with a live pod needs `podAffinity` to
  co-schedule on the same node, or it hits Multi-Attach errors.
- Replica count is **1, worker only** (single usable storage node, see
  ADR 005's RAM/disk reasoning). Two places control it and both have
  bitten: the `default-replica-count` *setting*, and the
  `numberOfReplicas` *parameter* baked into the `longhorn` StorageClass
  (which wins for every dynamically provisioned PVC, the first Immich
  volumes came up degraded at 3 replicas hours after the setting was
  fixed). The SC is regenerated from the `longhorn-storageclass`
  ConfigMap; fix it there, commands in cluster-rebuild.md step 3.
  Verify after any Longhorn reinstall *and after adding any service*:
  `kubectl -n longhorn-system get volumes.longhorn.io`, every volume
  should say `healthy`, not `degraded`.
- **A worker reboot bloats the control-node `longhorn-manager` for
  hours.** The reboot faults/AutoSalvages every volume; the manager (the
  controller leader, which sits on control) then runs the rebuilds plus
  the recurring snapshot/trim/backup jobs on all of them, growing its
  heap ~150MiB and holding it. On the thin 4GiB control node this trips
  `NodeMemoryLowControl` (`MemAvailable < 0.75GiB`) *after* the crashloop
  storm has cleared, looking unrelated. Reclaim it by bouncing the
  control-node manager (`kubectl delete pod -n longhorn-system -l
  app=longhorn-manager --field-selector spec.nodeName=k3s-control`), or
  give control 5GiB. See
  `docs/lessons/k8s/worker-reboot-alert-storm.md`.
- **`auto-salvage=true` does not mean auto-salvage works.** It skips any
  replica whose disk is `Schedulable: False`, so an over-provisioned disk
  turns a self-healing reboot into a 16-hour manual recovery. On
  2026-07-25 the manager logged `Bringing up 0 replicas for auto-salvage`
  4,367 times overnight and never recovered a single volume. Longhorn
  schedules on **provisioned** size, not actual usage, so the 200Gi
  `immich-library` counts in full at 44GiB used, and
  `storage-reserved-percentage-for-default-disk=30` had reserved 147GiB
  of a dedicated data disk that needs none. Check the condition, not the
  setting:
  `kubectl -n longhorn-system get nodes.longhorn.io k3s-worker1 -o jsonpath='{range .status.diskStatus.*}{.conditions[?(@.type=="Schedulable")].status}{" "}{.conditions[?(@.type=="Schedulable")].reason}{"\n"}{end}'`
  Manual salvage is clearing `failedAt` on the replica (what the UI
  button does):
  `kubectl -n longhorn-system patch replicas.longhorn.io <r> --type=merge -p '{"spec":{"failedAt":""}}'`.
  See `docs/lessons/storage/longhorn-autosalvage-blocked-diskpressure.md`.

## local-path / PersistentVolumes

**A PV's path cannot be edited.** `spec.persistentVolumeSource` is
immutable, so `kubectl patch pv ... spec.local.path` is rejected. Worse,
`kubectl delete pv` on a bound PV *appears* to succeed but parks it in
`Terminating` behind the `kubernetes.io/pv-protection` finalizer, which
only clears when the PV is no longer bound — so the old path stays live
and a re-`apply` hits the immutability error. Always server-dry-run first:

```bash
kubectl patch pv <pv> --type=merge --dry-run=server \
  -p '{"spec":{"local":{"path":"/new/path"}}}'
```

**Moving an existing local-path volume** therefore means recreating it,
and the new PV gets a new UID and so a new directory name:

1. `kubectl patch pv <pv> -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}'`
2. stop the consumer (see the ArgoCD note above — this is the hard part)
3. delete the **PVC**, which releases the PV; `Retain` keeps the data
4. let the PVC be recreated; it provisions a fresh PV at the new path
5. copy the old data into the new directory, matching ownership —
   check `ls -ln` on the original rather than assuming, these are
   `0:0` not `1000:1000`
6. delete the old directory and the `Released` PV

**`local-path-config` is not the knob.** The ConfigMap in `kube-system`
is owned by k3s and re-applied from
`/var/lib/rancher/k3s/server/manifests/local-storage.yaml` on every
restart. The durable setting is the k3s **server** flag
`--default-local-storage-path` (`k3s_local_storage_path` in Ansible). It
is cluster-wide, and it only affects PVs created *after* it changes.
Restart `local-path-provisioner` afterwards so it re-reads the config.

## k3s node operations

**`systemctl stop k3s-agent` does not stop the containers.** The unit is
`KillMode=process`, so the stop returns in ~0.1s having killed only the
k3s process — containerd's shims and all 52 containers keep running, with
Longhorn volumes still mounted. Anything that needs a quiescent
containerd data directory has to stop them separately.

`k3s-killall.sh` does it, but read it before reaching for it: it
`kill -9`s every shim tree and force-unmounts `/var/lib/kubelet/pods`,
which for three live postgres instances means an unclean shutdown. For a
planned window, TERM the container processes in dependency order instead
— workloads first so databases flush while their volumes are still up,
Longhorn/CSI second, `pause` sandboxes last — and leave `open-iscsi`
alone entirely. Done that way the 2026-08-10 move produced clean ext4
mounts on all 11 volumes with no journal recovery, against the
"potential data loss!" the July shutdown logged.

**Check the shutdown ordering actually applies.** The
`k3s-agent`-before-`open-iscsi` drop-in only orders units systemd is
stopping. If `k3s-agent` is *already* stopped when you reboot, systemd
has nothing to order and the containers get swept concurrently with
`open-iscsi` — the exact 2026-07-25 failure. Either reboot with
`k3s-agent` running, or stop the containers yourself first and confirm
`ls /sys/class/iscsi_session | wc -l` is 0 before rebooting.

## restic / backups

- `RESTIC_REPOSITORY` must start with `s3:https://`, without the `s3:`
  prefix restic "succeeds" against the pod's ephemeral disk and the
  bucket stays empty.
- `RESTIC_PASSWORD` exists only in the password manager. Losing it is
  permanent data loss.
- The B2 bucket lifecycle must be "keep only the last version", or
  `restic forget --prune` never actually frees space.

## Sealed Secrets

The controller's master key must be restored **before** ArgoCD syncs
anything, a fresh controller generates a new key and every SealedSecret
in the repo fails to decrypt. `kubeseal --fetch-cert` should match the
backed-up cert. `bootstrap/bootstrap.sh` refuses to start without the key
rather than warning, because the failure is silent until apps fail to
mount and unrecoverable short of re-sealing everything. See
`docs/runbooks/cluster-rebuild.md` step 4.

## Nextcloud identity

`instanceid`/`secret`/`passwordsalt` in `config.php` must match the
imported DB; they're in the `nextcloud-secrets` SealedSecret. Restore
the SealedSecret before the pod first starts, not after, or sessions and
encrypted fields break.

## WireGuard LXC (101)

Never `pct enter` it (or SSH into it through the tunnel) while the VPN
is active, network-namespace conflict freezes the container in D-state
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
**field:** the deprecated annotation silently doesn't apply on
k3s ≥ 1.30, the default cri-containerd profile denies `mount(2)`, and
CODE falls back to copying the whole LO tree per kit jail (~6ms → ~48s).
The capability list feeds *file capabilities* on
`coolmount`/`coolforkit-caps`; pid 1 showing `CapEff=0` is the healthy
state, don't "fix" it. See
`docs/lessons/k8s/collabora-slow-load-wordbook.md`.

## Monitoring

- Use `VMRule`/`VMServiceScrape` (VictoriaMetrics operator), **not**
  `PrometheusRule`/`ServiceMonitor`, one invalid CRD kind fails the
  whole Application's sync batch.
- An alert on a metric nobody scrapes never fires. Pair the important
  ones with an `absent()` guard (see `LonghornMetricsAbsent` in
  `homelab-rules.yaml`).
- local-path PVCs survive namespace deletion. When reinstalling a Helm
  app after a failed deploy, delete the PVCs explicitly, a reused
  Grafana PVC with a corrupt SQLite crashed every reinstall. See
  `docs/lessons/k8s/grafana-pvc-corruption.md`.
- **A worker reboot fires a stale crashloop alert storm.** Longhorn
  volumes reattach uncleanly on boot, so PVC-mounting pods crash-restart
  for a few minutes; meanwhile the alerter (also on the worker) is down,
  then flushes the whole batch on recovery, ~20 min late, for pods that
  are already healthy. `PodCrashLooping` is a restart-*rate* threshold
  (`increase[15m] > 3`, `for 5m`) and can't tell a reboot from a real
  crashloop. Triage by the *absence* of `PodOOMKilled`/`NodeMemoryLowWorker`
  (memory) and `LonghornVolumeDegraded` persisting (storage): only
  `PodCrashLooping` clustered after a reboot = benign, self-resolves. See
  `docs/lessons/k8s/worker-reboot-alert-storm.md`.
- **Alerts fire into email, and email does not wake anyone.** On
  2026-07-25 `LonghornVolumeDegraded` (critical) fired correctly at
  19:34 on a Saturday and eleven faulted volumes sat unattended for 16h.
  Detection was never the problem, which is the tempting wrong
  conclusion to draw. Confirm what actually happened before touching a
  rule, using the stored `ALERTS` series rather than Alertmanager's
  short-lived state:
  `max_over_time(ALERTS{alertname="LonghornVolumeDegraded"}[17h] @ <ts>)`.
  The fix is routing `severity: critical` to a channel that interrupts,
  not another rule. See `docs/reference/known-risks.md` #2.
- ArgoCD 3.x marks an app `Degraded` from CronJob health, comparing the
  CronJob's own `lastSuccessfulTime` against `lastScheduleTime`. Deleting
  the failed Job records does **not** clear it and neither does a hard
  refresh; it clears on the next successful run. Force one with
  `kubectl -n <ns> create job <name> --from=cronjob/<cronjob>`, which
  doubles as a backup verification.
- **`PortfolioMetricsAbsent` re-fires after every portfolio restart.**
  `portfolio_upstream_up` is populated lazily ("on last use"), so until
  the app actually fetches an upstream (a real `/api/*` hit, not a
  `/healthz` probe or static `/`), no series exists and `absent()` fires
  for 15m, even though the pod is healthy and being scraped. A single
  live page load creates the series and it resolves. The durable fix is
  in the **portfolio repo**: pre-register the gauge at 0 for each known
  upstream (`vm`, `gitea`) at startup so the series always exist, then
  `absent()` only fires on a genuinely broken pipeline and
  `PortfolioUpstreamDown` can evaluate from boot.

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

Verify versions with `helm search repo <chart>` before pinning, never
trust a version from memory. All chart `targetRevision`s in this repo
are pinned exactly; bumps are deliberate commits.

A pin guarantees the version, not the host. Chart repo URLs die on their
own schedule and a running cluster never notices, because it fetched the
chart months ago. Sealed Secrets moved org (`bitnami-labs` → `bitnami`) on
2026-06-15 and GitHub Pages does not redirect across org moves, so the URL
in this repo had been a bare 404 for six weeks before ArgoCD was first
asked to render it. Only a rebuild would have found it otherwise. See
`docs/reference/resources.md`.

## Declared is not applied

ArgoCD self-heals `k8s/`, so for anything in there a committed file and a
live cluster mean the same thing. **Below the cluster that equivalence is
false.** `ansible/` only runs when someone runs it, and `bootstrap/` only
on a rebuild. On 2026-07-27 the `k3s-agent`↔iSCSI shutdown ordering was
found still missing from the worker two days after the outage it exists to
prevent: the role was correct, the runbook documented it, and known-risks
listed it as owned — but nothing had ever executed it. `--check --diff`
compares declared against live and is the only thing that closes the gap.
See known-risks §6.
