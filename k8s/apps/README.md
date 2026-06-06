# k8s/apps

One ArgoCD Application per service. Each entry is a `<name>.yaml` Application manifest pointing at a `<name>/` directory containing the actual Kubernetes resources.

`root-app` (in `k8s/argocd/`) watches this directory and automatically picks up new Application files — adding a service here is enough for ArgoCD to start managing it.

**In-cluster services:** Namespace · Deployment · PVC · Service · Ingress · SealedSecret (+ backup CronJob if stateful)

**External services** (LXC backends): selectorless Service + hand-written EndpointSlice + Ingress. See `docs/runbooks/adding-a-service.md` for both patterns.
