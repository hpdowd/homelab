# Rebuilding from scratch

What it takes to get back to a working cluster from a freshly installed
Proxmox box. Hopefully I never need this, but if I do, it's here.

The order matters. Each step assumes the previous ones are done.

## 0. Before you start

Pull these out of the password manager first, without them you can't
restore anything:

- `RESTIC_PASSWORD` and the B2 access keys
- The Sealed Secrets controller's `master.key` (the private side of the
  encryption pair). Also kept on local disk somewhere safe
- Cloudflare API token (needed to recreate the tunnel, if it's gone)
- The git repo URL + a way to read it (this repo lives in Gitea, but if
  the cluster is gone there's no Gitea; so keep a clone on a laptop)

If the Sealed Secrets key is gone, every `SealedSecret` in this repo is
unrecoverable. You'd have to re-seal them all from the password manager,
which means the password manager actually has the underlying values.
This is the discipline. If a secret isn't in the password manager, it
isn't real.

## 1. Proxmox

Install Proxmox, get networking working with static IPs, then create
the ZFS mirror pool called `tank`. Wire up the LXCs that have to exist
outside k3s:

- 100 Technitium, DNS. Without it, `*.lan` doesn't work.
- 101 WireGuard, VPN + cloudflare-ddns. Don't break this one if
  you're remote.
- 102 AMP, game server, optional to bring up early.

Restore their `tank` subvolumes from the ZFS snapshot backup if you
have one, otherwise install fresh.

## 2. The k3s VMs

Two VMs:

- **300 control:** 2 vCPU, 4GiB RAM, static `192.168.1.10`
- **301 worker1:** 8 vCPU, 14GB RAM, static `192.168.1.11`, plus a
  500GB virtual disk (`vdb`) carved out of `tank` for Longhorn

Install k3s on both. The control node first:

```bash
curl -sfL https://get.k3s.io | sh -s - server \
  --disable traefik --disable servicelb \
  --node-ip 192.168.1.10
```

### Worker OS-level config (do this before workloads land)

**Run the Ansible playbook. Do not do this by hand.**

```bash
cd ansible
ansible-playbook -i inventory.ini site.yml --check --diff   # read the diff
ansible-playbook -i inventory.ini site.yml
```

That applies the journald cap, `/etc/rancher/k3s/config.yaml`, the
`k3s-agent` ↔ iSCSI shutdown ordering, and the `vdb` directories and bind
mount that keep containerd and local-path off the OS disk. It is
idempotent, it restarts
nothing but journald, and it is the only mechanism that reapplies any of
this. These steps used to live here as commands to copy; on 2026-07-27 the
iSCSI ordering was found missing from the live worker two days after the
outage it prevents, because a runbook step is only as good as the person
remembering to run it. See `known-risks.md` §6 and `ansible/README.md`.

Verify rather than assume — this is the check that would have caught it:

```bash
ssh k3s-worker1 systemctl show k3s-agent -p After -p TimeoutStopUSec
# After= must list open-iscsi.service and iscsid.service
# TimeoutStopUSec=5min
```

Why these two settings exist, both learned the hard way (see
`docs/lessons/storage/longhorn-autosalvage-blocked-diskpressure.md`):

**The journal cap.** journald defaults to 10% of the filesystem, ~4GiB of
the worker's 41GiB OS disk, on a disk already tight against its container
images.

**The iSCSI ordering.** On shutdown, systemd tears down `open-iscsi` while
containerd is still working through its stop timeout, dropping every iSCSI
session under mounted, actively-written Longhorn volumes. That is what
faulted all 11 volumes on 2026-07-25. Stock `k3s-agent` has no ordering
against iSCSI at all.

The drop-in goes on **`k3s-agent`**, not on `open-iscsi`, and the direction
is easy to invert. `After=` means "start after", and shutdown order is the
reverse: a unit that starts *after* B is stopped *before* B. So
`After=open-iscsi` on `k3s-agent` is what makes k3s-agent stop first.
`After=k3s-agent` on `open-iscsi` does the exact opposite and makes the bug
worse.

Grab the join token from `/var/lib/rancher/k3s/server/node-token`, then
on the worker:

```bash
curl -sfL https://get.k3s.io | K3S_URL=https://192.168.1.10:6443 \
  K3S_TOKEN=<token> sh -s - agent --node-ip 192.168.1.11
```

Copy `/etc/rancher/k3s/k3s.yaml` from the control node back to your
laptop's `~/.kube/config` and edit the server URL.

`kubectl get nodes` should show both. If it doesn't, fix that before
moving on.

## 3. Longhorn

Install via Helm (or the official manifest). Point its data dir at
`/mnt/longhorn` on `vdb`. Then make it the default storage class:

```bash
kubectl annotate sc longhorn storageclass.kubernetes.io/is-default-class="true"
```

Set the replica count to 1 (single-worker reality) and keep replicas
off the control node; it only has the 29G OS disk. **Two knobs, both
matter:** the `default-replica-count` setting only covers volumes whose
StorageClass doesn't say otherwise, and the stock `longhorn`
StorageClass hardcodes `numberOfReplicas: "3"`; so new PVCs ignore the
setting unless the StorageClass (via its source ConfigMap) is fixed too:

```bash
kubectl -n longhorn-system patch settings.longhorn.io default-replica-count \
  --type=merge -p '{"value":"{\"v1\":\"1\",\"v2\":\"1\"}"}'
# the SC is immutable but Longhorn regenerates it from this ConfigMap:
kubectl -n longhorn-system get cm longhorn-storageclass \
  -o jsonpath='{.data.storageclass\.yaml}' \
  | sed 's/numberOfReplicas: "3"/numberOfReplicas: "1"/' > /tmp/sc.yaml
kubectl -n longhorn-system create cm longhorn-storageclass \
  --from-file=storageclass.yaml=/tmp/sc.yaml --dry-run=client -o yaml \
  | kubectl apply -f -
kubectl -n longhorn-system patch nodes.longhorn.io k3s-control \
  --type=merge -p '{"spec":{"allowScheduling":false}}'
```

(The node object only exists once Longhorn has started on it, if the
patch 404s, wait and retry. Confirm with
`kubectl get sc longhorn -o jsonpath='{.parameters.numberOfReplicas}'`.)

### Disk reservation, set this before the disk is created

Longhorn reserves 30% of a disk by default. Left at 30 it reserves ~147GiB
of the 491GiB disk, and because Longhorn schedules on **provisioned** size
rather than actual usage, the disk crosses into `Schedulable: False` /
`DiskPressure` long before it is anywhere near full. An unschedulable disk
silently disables auto-salvage, which is how a routine reboot became a
16-hour outage on 2026-07-25.

The reserve is not free to set at zero either, and this changed on
2026-08-10. **`vdb` is no longer dedicated to Longhorn.** It now also
carries containerd's image store (~24GiB) and the local-path PVs (~6GiB),
both moved off the worker's OS disk (known-risks #3). The reserve is what
stops Longhorn from scheduling into space that data needs, so it has to
cover them with room to grow: 16% = 80GiB against ~30GiB in use today, and
~60GiB if containerd and the local-path claims both grow out to their
plausible maximum.

Squeezed from both sides, and the two failure modes are not symmetric:

- **Too low** and Longhorn schedules into space containerd needs. With
  333GiB actually free on `vdb`, this is not currently a credible failure.
- **Too high** and `ProvisionedLimit = StorageMaximum − reserved` drops
  under `ScheduledTotal` (351GiB of *provisioned* volume sizes), the disk
  goes `Schedulable: False`, and auto-salvage silently stops working. That
  is the 2026-07-25 outage, and it is the one that has actually happened.

So err low. The ceiling is ~140GiB; anything near it reproduces the
outage. There is also a softer ceiling worth respecting:
`LonghornProvisioningHeadroomLow` warns when `ScheduledTotal /
ProvisionedLimit > 0.9`, which a 100GiB reserve reaches at 0.8975 — close
enough that one new PVC would trip it.

| | GiB |
|---|---|
| StorageMaximum | 491.1 |
| reserved (16%) | 80.0 |
| ProvisionedLimit | 411.1 |
| ScheduledTotal | 351.0 |
| headroom | 60.1 |
| alert ratio | 0.854 (warns >0.90) |

Set the *setting* first, so the default disk is created correctly and a
rebuild never inherits the problem:

```bash
kubectl -n longhorn-system patch settings.longhorn.io \
  storage-reserved-percentage-for-default-disk \
  --type=merge -p '{"value":"16"}'
```

If the disk already exists, the setting does not retroactively change it,
so fix the node object too. The disk key is generated at creation, so look
it up rather than guessing (it was `default-disk-25a91b93472172c4` on the
current worker, but that does not survive a rebuild):

```bash
# go-template, not jsonpath — kubectl's jsonpath can't iterate a map with
# its keys, and `{range $k, $v := ...}` fails with "unrecognized character".
kubectl -n longhorn-system get nodes.longhorn.io k3s-worker1 \
  -o go-template='{{range $k,$v := .spec.disks}}{{$k}}  {{$v.path}}  reserved={{$v.storageReserved}}{{"\n"}}{{end}}'
# default-disk-25a91b93472172c4  /mnt/longhorn  reserved=158188673433
```

Then patch it (85899345920 = 80GiB ≈ 16% of the 527295578112
StorageMaximum; recompute if the disk is a different size):

```bash
kubectl -n longhorn-system patch nodes.longhorn.io k3s-worker1 --type=merge \
  -p '{"spec":{"disks":{"<disk-key>":{"storageReserved":85899345920}}}}'
```

Verify the condition, not the setting; the setting can be right while the
disk is still wrong:

```bash
kubectl -n longhorn-system get nodes.longhorn.io k3s-worker1 \
  -o jsonpath='{range .status.diskStatus.*}{.conditions[?(@.type=="Schedulable")].status}{" "}{.conditions[?(@.type=="Schedulable")].reason}{"\n"}{end}'
# want: True    (False + DiskPressure means auto-salvage is dead)
```

Re-check this after adding any service with a large PVC. `immich-library`
alone provisions 200Gi while using ~44GiB, and it is provisioned size
that counts against the limit.

**Verify it actually took, after the first PVCs exist:**

```bash
kubectl -n longhorn-system get volumes.longhorn.io
# every volume: robustness "healthy", not "degraded"
```

This bit once: the setting never got applied, the default stayed 3, and
every volume sat permanently degraded, with replicas quietly landing on
the control node's OS disk, until a review caught it months later. A
degraded volume on this cluster is *always* wrong; see gotchas.md.

Turn on the daily snapshot schedule in the Longhorn UI (retain 7).

## 4. Bootstrap ArgoCD

Sealed Secrets, ArgoCD, the repo credentials and `root-app`, in the order
that matters. **This is a script now — do not do it by hand.**

```bash
export MASTER_KEY=~/secure/sealed-secrets-master-key.yaml
export REPO_TOKEN='<gitea token, repo read scope>'

cd bootstrap
./bootstrap.sh --check    # preflight only, changes nothing
./bootstrap.sh
```

It is idempotent, so a run that dies halfway can be re-run rather than
unpicked. `bootstrap/README.md` has the full walkthrough and ADR 017 has why
it is a script rather than more Ansible; the parts worth knowing before you
run it:

- **It refuses to start without the master key**, rather than warning. A
  controller installed without it generates a *fresh* keypair, and every
  `SealedSecret` in this repo is then encrypted against a key that no longer
  exists anywhere. That is unrecoverable short of re-sealing every secret
  from the password manager, and it stays silent until apps start failing to
  mount. Stopping at preflight is much cheaper.
- **Versions are pinned** in `bootstrap/versions.env`, read off the running
  cluster. This section used to install from `releases/latest`, `stable` and
  `main` — three moving pointers, so two rebuilds a month apart produced two
  different clusters.
- **MetalLB is no longer a step.** It used to be installed here from the
  upstream native manifest, but the live install is the Helm chart via
  `k8s/infrastructure/metallb.yaml`. Doing both puts two differently-shaped
  MetalLBs in one namespace for ArgoCD to fight with. ArgoCD brings it up on
  its own, and nothing here needs a LoadBalancer IP — ArgoCD is reached by
  port-forward until Traefik is up.

Verify the controller is serving the key you expect before trusting any
sync:

```bash
kubeseal --fetch-cert | diff - <your-backed-up-cert>
```

Then watch the sync settle. During a fresh bootstrap the `argocd.lan`
ingress doesn't exist yet (it's one of the things being synced), so the
port-forward is correct here, not drift:

```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443
# https://localhost:8080  user: admin, password: kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath='{.data.password}' | base64 -d
```

`longhorn` and `sealed-secrets` will both show `OutOfSync`. That is correct:
both are manual-sync by design. **Do not "Sync All."** Read the headers in
`k8s/infrastructure/{longhorn,sealed-secrets}.yaml` first.

Once everything is green, `argocd.lan` is the normal way in (see
`docs/reference/operations.md`).

## 5. Wait for everything to be green

In order of "should come up first":

1. MetalLB (the chart itself, then the IPAddressPool and L2Advertisement —
   all three now come from ArgoCD, nothing is installed by hand)
2. Traefik (will get 192.168.1.200 from MetalLB)
3. cloudflared (the SealedSecret with the tunnel token has to decrypt
   cleanly, which means step 4 above worked)
4. cert-manager + the `henrydowd-dev` Certificate in the traefik
   namespace (its Cloudflare-token SealedSecret also depends on the
   master key). First issuance takes a few minutes; verify with
   `kubectl -n traefik get certificate henrydowd-dev` → `READY True`,
   then LAN HTTPS is valid again. If it sticks at `pending`, read the
   Challenge's `status.reason` and see
   `docs/lessons/networking/certmanager-dns01-split-horizon.md`.
5. App namespaces, Postgres / Redis, then the apps themselves

If something's stuck, the usual suspects: Sealed Secrets master key
isn't the right one (apps can't read their creds); the ArgoCD patch
wasn't applied (external services have no endpoints); MetalLB hasn't
finished and Traefik's Service is `<pending>`.

## 6. Restore the data

By this point the apps are running but empty (Nextcloud will be a
fresh install, Gitea will be an empty Gitea, etc.). To get the actual
data back, follow `docs/runbooks/restore-procedure.md`. The condensed version:

- Scale the app to 0
- Restore the data PVC from restic
- For Nextcloud, also restore the DB dump and run `occ files:scan --all`
- For Gitea, run `gitea admin regenerate hooks` after scaling back up

## 7. Check the boring stuff still works

- Public hostnames resolve and load. Test from outside the LAN
  (mobile data, not WiFi) to confirm cloudflared is doing its job.
- LAN hostnames work and stay LAN-local (Technitium split-horizon).
- Logging in everywhere, Nextcloud especially, because if the
  identity values in the SealedSecret didn't restore correctly, every
  encrypted field is unreadable.
- The backup CronJobs run successfully overnight. `restic check`
  against B2 to confirm the repos are still intact.

If all that passes, you're back.
