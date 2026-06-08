# Day-to-day operations

The commands I actually reach for, and what they're for. Not a
comprehensive kubectl reference — just the things I do here, often
enough that they're worth writing down.

## ArgoCD

The UI lives at `http://argocd.lan` (Traefik ingress, LAN-only). CLI
login:

```bash
argocd login argocd.lan --username admin --insecure --grpc-web
```

`--insecure` because Traefik fronts it with a self-signed `.lan` cert;
`--grpc-web` because the API rides an HTTP ingress, not ArgoCD's native
gRPC port. The server runs in `server.insecure` mode
(`argocd-cmd-params-cm`) so it serves plain HTTP behind Traefik.

Fallback when the ingress isn't available (e.g. mid-rebuild before
`argocd.lan` exists — see `docs/runbooks/cluster-rebuild.md` step 6):

```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443
# https://localhost:8080  user: admin
argocd login localhost:8080 --username admin --insecure
```

Force-sync an app:

```bash
argocd app sync <appname>
```

See every app's status at once:

```bash
kubectl get applications -n argocd
```

### Pausing autosync for manual surgery

When I want to mess with something by hand without ArgoCD putting it
back instantly, I disable selfHeal:

```bash
argocd app set <appname> --sync-policy none
# ... do the thing ...
argocd app set <appname> --sync-policy automated --auto-prune --self-heal
```

Common case: editing a Deployment to scale it to 0 for a maintenance
window, or temporarily increasing replicas.

## Sealed Secrets

The two-step is: make a normal Secret, then pipe it through `kubeseal`
to encrypt it against the in-cluster controller's public key. The
result is a `SealedSecret` that's safe to commit.

```bash
kubectl create secret generic <name> --namespace <ns> \
  --from-literal=key=value \
  --dry-run=client -o yaml | \
  kubeseal --controller-name sealed-secrets-controller \
  --controller-namespace kube-system -o yaml > sealed-secret.yaml
```

Multiple values? Repeat `--from-literal=k=v` or use `--from-file`.

Once committed, ArgoCD picks it up, the controller decrypts it into a
real Secret, and the pod that wants it can mount or env-from it
normally.

**To verify the cluster's controller key matches what I expect:**

```bash
kubeseal --fetch-cert
```

The output should match the cert that was active when the existing
SealedSecrets in this repo were sealed. If it doesn't, the controller
has a different key and nothing in the repo can decrypt — usually
that means the master key wasn't restored after a rebuild.

## Pods + Deployments

Restart a Deployment without changing its spec:

```bash
kubectl rollout restart deployment/<name> -n <namespace>
```

Tail logs on whatever pod is currently serving:

```bash
kubectl logs -n <ns> -l app=<label> --tail=200 -f
```

Get inside a running pod:

```bash
kubectl exec -it -n <ns> <podname> -- /bin/sh
```

## Nextcloud-specific

Run an `occ` command (the Nextcloud CLI). Has to run as `www-data` or
it complains about file ownership:

```bash
POD=$(kubectl get pod -n nextcloud -l app=nextcloud -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n nextcloud $POD -- su -s /bin/sh www-data -c "php occ status"
```

Most-used `occ` subcommands:

- `php occ status` — quick health check
- `php occ files:scan --all` — rebuild the file index. Run after a
  data restore or if files appear missing in the UI but exist on disk
- `php occ maintenance:mode --on` / `--off` — block all access. Useful
  before manual DB ops
- `php occ db:add-missing-indices` and `db:add-missing-columns` —
  silence the admin warnings after an upgrade

## MetalLB

What IPs has it actually handed out?

```bash
kubectl get svc -A | grep LoadBalancer
```

Expect to see Traefik holding 192.168.1.200 and probably nothing else
unless I've added a service that asks for its own LB IP.

## Longhorn

Volumes in the cluster:

```bash
kubectl get volumes -n longhorn-system
```

For anything nontrivial, just open the Longhorn UI (port-forward the
`longhorn-frontend` service in `longhorn-system`). The CLI is fine
for "is it healthy" but the UI is the right tool for actual ops.

## ZFS (on the Proxmox host)

Manual snapshot of the whole pool, recursively:

```bash
zfs snapshot -r tank@manual-$(date +%F)
```

List snapshots:

```bash
zfs list -t snapshot
```

The daily cron already snapshots at 02:00 with a 7-day retention. The
manual one is for "I'm about to do something risky and I want a
hard rollback".

## Backups

Check the restic repos are intact (run on a laptop with restic and
the env vars from the password manager):

```bash
export RESTIC_REPOSITORY="s3:https://s3.eu-central-003.backblazeb2.com/hpd.homelab/nextcloud"
export RESTIC_PASSWORD="..."
export AWS_ACCESS_KEY_ID="..."
export AWS_SECRET_ACCESS_KEY="..."

restic snapshots         # list what's in the repo
restic check             # verify integrity. Cheap. Run after anything weird
```

For Gitea, same but swap the URL's last segment.

To run that same check *inside* the cluster using the already-sealed
credentials:

```bash
kubectl run restic-check -n <ns> --rm -it --restart=Never --image=alpine:3.20 \
  --overrides='{"spec":{"containers":[{"name":"restic-check","image":"alpine:3.20","command":["/bin/sh","-c","apk add --no-cache restic && restic snapshots && restic check"],"envFrom":[{"secretRef":{"name":"backup-credentials"}}]}]}}'
```

## When something looks wrong

A short diagnosis flow that catches most of what bites me:

1. **App not loading from outside?** `curl -H "Host: <hostname>"
   http://192.168.1.200/ -I` — tests Traefik directly with the right
   Host header, bypassing Cloudflare and cloudflared. If this works,
   the problem is in the tunnel. If it doesn't, the problem is
   Traefik or the service.
2. **404 from Traefik?** Check the Ingress has
   `ingressClassName: traefik`. Check there's no `router.entrypoints:
   websecure` annotation (that 404s the plaintext tunnel hit).
3. **External LXC service "no available server"?** The ArgoCD
   `EndpointSlice` exclusion patch wasn't applied or got overwritten.
   See `docs/runbooks/cluster-rebuild.md` step 6.
4. **SealedSecret won't decrypt?** Master key mismatch. Either the
   secret was sealed against a different cluster, or this cluster's
   key got regenerated. Compare `kubeseal --fetch-cert` to the cert
   in the password manager.
5. **Pod stuck in `ContainerCreating` with a volume error?** Almost
   always Longhorn-related. Open the Longhorn UI and look at the
   volume state. Sometimes it's an RWO multi-attach trying to mount
   the same PVC into two pods (e.g. backup pod scheduled on a
   different node than the app — fix with podAffinity).
