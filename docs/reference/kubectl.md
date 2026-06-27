# kubectl cheat-sheet

The commands for checking what the cluster is doing and whether it's
healthy. `operations.md` covers the task-oriented stuff (ArgoCD login,
sealing secrets, the diagnosis flow); this is the reference for poking
at state. Everything here talks to the apiserver on the k3s control
node at `https://192.168.1.10:6443`, read from `~/.kube/config`.

## 30-second health sweep

The six commands I run to answer "is anything wrong right now". If all
six come back clean the cluster is healthy.

```bash
kubectl get nodes -o wide
kubectl top nodes
kubectl get pods -A | grep -vE 'Running|Completed'                       # anything unhealthy
kubectl get events -A --field-selector type=Warning --sort-by=.lastTimestamp | tail -20
kubectl get pvc -A | grep -v Bound                                       # stuck storage claims
kubectl get applications -n argocd                                       # GitOps drift
```

## Cluster + nodes

```bash
kubectl get nodes -o wide          # Ready? IPs, kernel, k3s version
kubectl top nodes                  # actual CPU/RAM per node (metrics-server ships with k3s)
kubectl cluster-info               # apiserver + core endpoints
kubectl version                    # client vs server skew
kubectl describe node <node> | grep -A8 'Allocated resources'   # how full a node is
```

The worker is RAM-constrained (see `capacity-headroom.md`), so
`Allocated resources` on it is the number that actually gates new
services.

## Pods + workloads

```bash
kubectl get pods -A -o wide                       # all pods, which node each is on
kubectl get deploy,sts,ds -A                      # READY counts for deployments/statefulsets/daemonsets
kubectl get all -n <ns>                           # quick overview of one namespace
kubectl top pods -A --sort-by=memory              # biggest memory hogs
kubectl get pods -A --field-selector=status.phase=Pending    # unschedulable (usually RAM)
kubectl get pods -A | grep -vE 'Running|Completed'
```

`READY 0/1` or a climbing restart count is the signal to drill in.

## Events: the "what just happened" feed

```bash
kubectl get events -A --sort-by=.lastTimestamp | tail -30
kubectl get events -n <ns> --sort-by=.lastTimestamp
kubectl get events -A --field-selector type=Warning
```

Catches OOMKills, failed image pulls, failed mounts, probe failures,
evictions, the things `describe` shows at the bottom but cluster-wide.

## Drilling into a problem pod

```bash
kubectl describe pod <pod> -n <ns>             # events at the bottom: scheduling, image pull, OOM, probes
kubectl logs <pod> -n <ns>
kubectl logs <pod> -n <ns> --previous          # logs from the crashed instance (key for CrashLoopBackOff)
kubectl logs <pod> -n <ns> -f                  # follow live
kubectl logs -n <ns> -l app=<label> --tail=200 -f       # whatever pod currently serves the label
kubectl logs <pod> -n <ns> -c <container>      # multi-container pod
```

## Networking + ingress (Traefik, MetalLB)

```bash
kubectl get svc -A | grep LoadBalancer    # MetalLB IPs handed out (expect Traefik on 192.168.1.200)
kubectl get ingressroute -A               # Traefik's CRD: the actual routes
kubectl get ingress -A                    # standard Ingress objects
kubectl get endpoints <svc> -n <ns>       # backend pods behind a service; empty = broken
kubectl -n kube-system logs deploy/traefik
```

## Storage (Longhorn, local-path)

```bash
kubectl get pvc -A                        # Bound vs Pending (Pending = no volume)
kubectl get pv
kubectl get storageclass                  # longhorn vs local-path
kubectl get volumes -n longhorn-system    # Longhorn volume health
kubectl describe pvc <name> -n <ns>       # why a claim is stuck
```

For anything beyond "is it healthy", open the Longhorn UI rather than
the CLI.

## GitOps + secrets

```bash
kubectl get applications -n argocd        # Synced & Healthy? OutOfSync = drift
kubectl get sealedsecrets -A              # the committed encrypted secrets
kubectl get secrets -n <ns>              # the decrypted Secret the controller produced
kubectl -n kube-system logs deploy/sealed-secrets-controller   # if a Secret never materialized
```

Sealing new secrets and the master-key check live in `operations.md`.

## Inspecting objects

```bash
kubectl get pod <pod> -n <ns> -o yaml
kubectl get pod <pod> -n <ns> -o jsonpath='{.status.containerStatuses[*].restartCount}'
kubectl get pods -A -w                    # watch live, updates in place
kubectl get pods -n <ns> --show-labels
kubectl explain deployment.spec.strategy  # field docs, offline
```

## Interacting + rollouts

```bash
kubectl exec -it <pod> -n <ns> -- /bin/sh         # tunnels through the apiserver
kubectl port-forward svc/<svc> 8080:80 -n <ns>    # reach a service from the laptop
kubectl rollout status deploy/<name> -n <ns>
kubectl rollout restart deploy/<name> -n <ns>     # bounce all pods, rolling
kubectl rollout undo deploy/<name> -n <ns>        # roll back to the previous revision
```

## Quality-of-life

```bash
alias k=kubectl
source <(kubectl completion zsh)          # tab-complete resources and namespaces
```

`kubens`/`kubectx` for switching namespace and context without `-n`
everywhere, and `stern` for tailing logs across many pods at once
(both via `kubectl krew`).
