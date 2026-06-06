# Adding a new service

The shape every service in this repo follows. The point of writing this
down is so I don't have to reverse-engineer it from existing services
every time I add something new.

There are roughly two cases: a service that runs *in* the cluster, and
a service that runs *outside* the cluster (an LXC, another machine on
the LAN) that I want to proxy through Traefik for routing uniformity.

## In-cluster service

1. **Make a directory** under `k8s/apps/<name>/`.

2. **Decide if it gets its own namespace.** Almost always yes. Add a
   `namespace.yaml`:
   ```yaml
   apiVersion: v1
   kind: Namespace
   metadata:
     name: <name>
   ```

3. **Persistent storage** — if the service has state, add a PVC. Pick
   Longhorn for app data (backed up, replicated when there's more than
   one worker), local-path for throwaway stuff like metrics:
   ```yaml
   apiVersion: v1
   kind: PersistentVolumeClaim
   metadata:
     name: <name>-data
     namespace: <name>
   spec:
     accessModes: [ReadWriteOnce]
     storageClassName: longhorn
     resources: { requests: { storage: 10Gi } }
   ```
   RWO matters because of Longhorn — only one pod at a time can mount it.
   That means the Deployment strategy has to be `Recreate`, not the
   default `RollingUpdate` (which would deadlock).

4. **Secrets** — anything sensitive goes in a `SealedSecret`. Generate
   it with `kubeseal` (see `docs/reference/operations.md`), drop it in
   `sealed-secret.yaml`. The Secret name becomes whatever you give
   `kubectl create secret generic`.

5. **The Deployment** — standard k8s. A few things to remember:
   - Pin the image tag. Don't use `:latest`. Floating to `:1` or
     `:33-apache` is fine; floating to `:latest` is a way to find out
     about breaking changes when you're not at the keyboard.
   - Set resource `requests` (so the scheduler knows what to do) and
     `limits` (so a runaway pod can't take the node down with it).
   - If the PVC is RWO, set `strategy.type: Recreate`.
   - Probes: at minimum a `livenessProbe`. If the app takes a while to
     start (Nextcloud first boot, anything that runs migrations), add a
     `startupProbe` too with a generous `failureThreshold`.

6. **A Service** — a normal ClusterIP Service pointing at the
   Deployment's pods. Nothing fancy.

7. **An Ingress** so Traefik routes traffic to it:
   ```yaml
   apiVersion: networking.k8s.io/v1
   kind: Ingress
   metadata:
     name: <name>
     namespace: <name>
   spec:
     ingressClassName: traefik          # required — silently ignored without it
     rules:
       - host: <name>.henrydowd.dev
         http:
           paths:
             - path: /
               pathType: Prefix
               backend:
                 service: { name: <name>, port: { number: <port> } }
       - host: <name>.lan
         http:
           paths:
             - path: /
               pathType: Prefix
               backend:
                 service: { name: <name>, port: { number: <port> } }
   ```
   **Do not** add `traefik.ingress.kubernetes.io/router.entrypoints:
   websecure`. The cloudflared tunnel hits Traefik over plain HTTP, so
   a websecure-only router 404s public traffic. Omitting the annotation
   makes the router serve both entrypoints.

8. **The ArgoCD Application** — drop a file at `k8s/apps/<name>.yaml`
   pointing at the directory you just made:
   ```yaml
   apiVersion: argoproj.io/v1alpha1
   kind: Application
   metadata:
     name: <name>
     namespace: argocd
   spec:
     project: default
     source:
       repoURL: https://git.henrydowd.dev/henry/homelab.git
       targetRevision: HEAD
       path: k8s/apps/<name>
     destination:
       server: https://kubernetes.default.svc
       namespace: <name>
     syncPolicy:
       automated: { prune: true, selfHeal: true }
       syncOptions: [ CreateNamespace=true ]
   ```
   `root-app` watches `k8s/apps/` and will pick this up automatically.

9. **Add DNS** for the LAN hostname in Technitium — `<name>.lan` →
   192.168.1.200. The public hostname is already covered by the
   `*.henrydowd.dev` wildcard at Cloudflare.

10. **If it has irreplaceable data, write a backup CronJob.** Either
    pattern works depending on the storage:
    - **Live, no downtime** — use podAffinity to colocate with the app
      pod and mount the PVC read-only. Works when the data on disk is
      consistent at any moment (file storage, append-only logs). See
      `nextcloud/backup-cronjob.yaml`.
    - **Scale-down** — scale the Deployment to 0, mount the volume,
      back up, scale back to 1. The only safe option for embedded
      databases like SQLite. Needs an RBAC `Role` so the job can patch
      its own Deployment. See `gitea/backup-cronjob.yaml` +
      `gitea/backup-rbac.yaml`.

    Either way, point the job at a new restic repo path under the
    existing B2 bucket: `s3:https://...backblazeb2.com/hpd.homelab/<name>`.

## External service (LXC or another host)

When the service itself stays put but I want Traefik to handle the
public/LAN routing:

1. **Service with no selector** — this is the unusual bit. A normal
   Service has a `selector` that points at pods; this one doesn't,
   because the backend isn't a pod:
   ```yaml
   apiVersion: v1
   kind: Service
   metadata:
     name: <name>-external
     namespace: <name>
   spec:
     ports:
       - port: <port>
         targetPort: <port>
         protocol: TCP
   ```

2. **A hand-written EndpointSlice** giving the Service the IP and port
   of the real backend:
   ```yaml
   apiVersion: discovery.k8s.io/v1
   kind: EndpointSlice
   metadata:
     name: <name>-external
     namespace: <name>
     labels:
       kubernetes.io/service-name: <name>-external    # ties to the Service
   addressType: IPv4
   endpoints:
     - addresses: [ "192.168.1.X" ]
       conditions:
         ready: true                                  # required — Traefik treats
                                                      # missing-or-false as "no backend"
   ports:
     - port: <port>
       protocol: TCP
   ```

3. **A regular Ingress** pointing at the Service (same shape as step 7
   above).

4. **An ArgoCD Application** (same as step 8 above).

5. **DNS** for the LAN hostname.

Two things to remember about external services:

- ArgoCD excludes `EndpointSlice` by default. The bootstrap patch in
  `docs/runbooks/cluster-rebuild.md` step 6 removes that exclusion. If it isn't
  applied, the EndpointSlice doesn't sync, Traefik sees no backend, and
  the error message is "no available server" — not "missing
  EndpointSlice", which would be too helpful.
- If the backend speaks HTTPS with a self-signed cert (Proxmox is the
  obvious case), you need a Traefik `IngressRoute` + `ServersTransport`
  with `insecureSkipVerify: true` instead of a plain Ingress. See
  `k8s/apps/proxmox/` for the worked example.

## Final checks

After ArgoCD syncs:

- `kubectl get pods -n <name>` — pod is running
- `kubectl get svc -n <name>` — Service exists, has the right port
- `kubectl get ingress -n <name>` — Ingress is admitted by Traefik
  (`ingressClassName: traefik` is set)
- Hit the LAN hostname from the LAN, hit the public hostname from
  somewhere outside the LAN (mobile data, not WiFi).

If both work, you're done. If only the LAN one works, the cloudflared
side isn't routing — usually the Ingress accidentally got a
`websecure` entrypoint pinned, or the hostname isn't in the tunnel's
Cloudflare DNS coverage (the `*.henrydowd.dev` wildcard should cover
it, but it's worth a sanity check).
