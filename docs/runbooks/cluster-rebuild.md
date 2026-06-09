# Rebuilding from scratch

What it takes to get back to a working cluster from a freshly installed
Proxmox box. Hopefully I never need this, but if I do, it's here.

The order matters. Each step assumes the previous ones are done.

## 0. Before you start

Pull these out of the password manager first — without them you can't
restore anything:

- `RESTIC_PASSWORD` and the B2 access keys
- The Sealed Secrets controller's `master.key` (the private side of the
  encryption pair). Also kept on local disk somewhere safe
- Cloudflare API token (needed to recreate the tunnel, if it's gone)
- The git repo URL + a way to read it (this repo lives in Gitea, but if
  the cluster is gone there's no Gitea — so keep a clone on a laptop)

If the Sealed Secrets key is gone, every `SealedSecret` in this repo is
unrecoverable. You'd have to re-seal them all from the password manager,
which means the password manager actually has the underlying values.
This is the discipline. If a secret isn't in the password manager, it
isn't real.

## 1. Proxmox

Install Proxmox, get networking working with static IPs, then create
the ZFS mirror pool called `tank`. Wire up the LXCs that have to exist
outside k3s:

- 100 Technitium — DNS. Without it, `*.lan` doesn't work.
- 101 WireGuard — VPN + cloudflare-ddns. Don't break this one if
  you're remote.
- 102 AMP — game server, optional to bring up early.

Restore their `tank` subvolumes from the ZFS snapshot backup if you
have one, otherwise install fresh.

## 2. The k3s VMs

Two VMs:

- **300 control** — 2 vCPU, 3GB RAM, static `192.168.1.10`
- **301 worker1** — 8 vCPU, 14GB RAM, static `192.168.1.11`, plus a
  500GB virtual disk (`vdb`) carved out of `tank` for Longhorn

Install k3s on both. The control node first:

```bash
curl -sfL https://get.k3s.io | sh -s - server \
  --disable traefik --disable servicelb \
  --node-ip 192.168.1.10
```

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

Set the default replica count to 1 (single-worker reality):

```bash
kubectl -n longhorn-system edit setting default-replica-count
# value: "1"
```

Turn on the daily snapshot schedule in the Longhorn UI (retain 7).

## 4. Sealed Secrets

Install the controller:

```bash
kubectl apply -f https://github.com/bitnami-labs/sealed-secrets/releases/latest/download/controller.yaml
```

**Critical step:** restore the master key from backup before anything
in this repo gets synced. Without it, the controller generates a fresh
key, and every `SealedSecret` in git is encrypted against the *old*
key, which no longer exists in the cluster. Result: every secret fails
to decrypt and every dependent app refuses to start.

```bash
kubectl apply -f <path-to>/sealed-secrets-master-key.yaml
kubectl rollout restart deployment sealed-secrets-controller -n kube-system
```

Verify with `kubeseal --fetch-cert` — the returned cert should match
your backed-up one.

## 5. MetalLB

```bash
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/main/config/manifests/metallb-native.yaml
```

The IPAddressPool and L2Advertisement come from this repo (via ArgoCD
once it's up). For now, that's it.

## 6. ArgoCD

Install:

```bash
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
```

**The bootstrap patch** (this *must* be applied before ArgoCD starts
syncing things — the external-LXC services depend on it):

```bash
kubectl patch configmap argocd-cm -n argocd --type merge -p '{
  "data": {
    "resource.exclusions": "- apiGroups:\n  - \"\"\n  kinds:\n  - Endpoints\n- apiGroups:\n  - coordination.k8s.io\n  kinds:\n  - Lease\n- apiGroups:\n  - authentication.k8s.io\n  - authorization.k8s.io\n  kinds:\n  - SelfSubjectReview\n  - TokenReview\n  - LocalSubjectAccessReview\n  - SelfSubjectAccessReview\n  - SelfSubjectRulesReview\n  - SubjectAccessReview\n- apiGroups:\n  - certificates.k8s.io\n  kinds:\n  - CertificateSigningRequest\n- apiGroups:\n  - cert-manager.io\n  kinds:\n  - CertificateRequest\n"
  }
}'
kubectl rollout restart deployment argocd-server -n argocd
```

This removes `EndpointSlice` from ArgoCD's default exclusion list. Skip
it and the EndpointSlices that point Traefik at AMP and Proxmox will
silently not get synced — Traefik will return "no available server"
and the cause will not be obvious.

Now point ArgoCD at this repo:

```bash
kubectl apply -f k8s/argocd/root-app.yaml
```

`root-app` discovers everything else — including the `argocd-ingress`
app, which syncs `argocd-cmd-params-cm` (`server.insecure: "true"`) and
the `argocd.lan` Ingress. **But a ConfigMap change does not auto-restart
`argocd-server`**, so even after root-app reports synced, the server is
still running in its default (TLS) mode and the `argocd.lan` ingress
won't work. Restart it once more after the sync settles:

```bash
kubectl rollout restart deployment argocd-server -n argocd
```

Only after this restart does the server come up in insecure HTTP mode
and serve cleanly behind Traefik at `argocd.lan`.

Watch the sync progress in the ArgoCD UI. During a fresh bootstrap the
`argocd.lan` ingress doesn't exist yet (it's one of the things being
synced), so use the port-forward here — this is correct for bootstrap,
not drift:

```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443
# https://localhost:8080  user: admin, password: kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath='{.data.password}' | base64 -d
```

Once everything is green and you've done the restart above, `argocd.lan`
is the normal way in (see `docs/reference/operations.md`).

## 7. Wait for everything to be green

In order of "should come up first":

1. MetalLB config (IPAddressPool, L2Advertisement)
2. Traefik (will get 192.168.1.200 from MetalLB)
3. cloudflared (the SealedSecret with the tunnel token has to decrypt
   cleanly, which means step 4 above worked)
4. App namespaces, Postgres / Redis, then the apps themselves

If something's stuck, the usual suspects: Sealed Secrets master key
isn't the right one (apps can't read their creds); the ArgoCD patch
wasn't applied (external services have no endpoints); MetalLB hasn't
finished and Traefik's Service is `<pending>`.

## 8. Restore the data

By this point the apps are running but empty (Nextcloud will be a
fresh install, Gitea will be an empty Gitea, etc.). To get the actual
data back, follow `docs/runbooks/restore-procedure.md`. The condensed version:

- Scale the app to 0
- Restore the data PVC from restic
- For Nextcloud, also restore the DB dump and run `occ files:scan --all`
- For Gitea, run `gitea admin regenerate hooks` after scaling back up

## 9. Check the boring stuff still works

- Public hostnames resolve and load. Test from outside the LAN
  (mobile data, not WiFi) to confirm cloudflared is doing its job.
- LAN hostnames work and stay LAN-local (Technitium split-horizon).
- Logging in everywhere — Nextcloud especially, because if the
  identity values in the SealedSecret didn't restore correctly, every
  encrypted field is unreadable.
- The backup CronJobs run successfully overnight. `restic check`
  against B2 to confirm the repos are still intact.

If all that passes, you're back.
