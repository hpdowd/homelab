# Incident: Monitoring stack — six-bug sync cascade (orphaned app → OOMKill)

## Date
2026-06-08

## Time lost
~Several hours — each fix unblocked the sync just enough to expose the next failure.

## Status
Resolved.

## Context
- **System / component:** `victoria-metrics-k8s-stack` (chart 0.81.0), namespace
  `monitoring`, deployed via ArgoCD. Specifically the bundled Grafana, plus the
  resources in `k8s/apps/monitoring/` (SealedSecret, alert rules, dashboard ConfigMap).
- **Scope:** Monitoring stack only. Grafana would not start; the SealedSecret holding
  the Grafana admin credentials was never materialised into a Secret.
- **State before:** A half-finished Sealed Secrets migration. The Grafana values had been
  pointed at `admin.existingSecret: grafana-admin-creds`, but the Secret did not exist in
  the cluster. Grafana was in `CreateContainerConfigError`.

## Symptoms
- `vm-grafana` pods in `CreateContainerConfigError`, then later `CrashLoopBackOff`, then
  `OOMKilled`. The error surface changed at each stage as one cause was fixed and the next
  was revealed.
- `kubectl port-forward svc/vm-grafana 3000:80` failed with `connection refused` inside the
  pod netns — a symptom of the container not listening, not a port-forward fault.
- Key error lines, in the order they appeared:
  ```text
  Error: secret "grafana-admin-creds" not found
  Application.argoproj.io "kiwix" is invalid: spec.syncPolicy.syncOptions: ... must be of type array
  could not find monitoring.coreos.com/PrometheusRule ... Make sure the "PrometheusRule" CRD is installed
  Failed to install plugin victoriametrics-datasource@: 404: Plugin not found
  Datasource provisioning error: ... Only one datasource per organization can be marked as default
  Last State: Terminated  Reason: OOMKilled  Exit Code: 137
  ```

## Investigation
What was checked, including the dead ends.

- **Bug 1 — Grafana `CreateContainerConfigError`.**
  - Hypothesis: key mismatch in the existing secret. → Wrong direction.
  - `kubectl describe pod` named `secret "grafana-admin-creds" not found`. The SealedSecret
    file existed in the repo (`k8s/apps/monitoring/grafana-admin-secret.sealed.yaml`), correctly
    scoped, correct keys — yet `kubectl get sealedsecret -n monitoring` returned nothing. So the
    resource was never applied at all.
  - **Root finding (one level up):** `root-app` watches `path: k8s/apps` with **no
    `directory.recurse: true`**, so it only applies Application manifests sitting *directly* in
    `k8s/apps/`. There was no `k8s/apps/monitoring.yaml`, so the entire `k8s/apps/monitoring/`
    directory was orphaned — SealedSecret, alert rules, and dashboard ConfigMap all invisible to
    ArgoCD. Grafana's Deployment existed only because it comes from `k8s/infrastructure/`
    (synced by the `infrastructure` app), and its values referenced a Secret that the orphaned
    directory was supposed to create.

- **Bug 2 — root-app stuck `OutOfSync` after adding the monitoring app.**
  - `argocd app get root-app --hard-refresh` showed the new `monitoring` app applied, but the
    sync still failed on `kiwix`: `syncOptions ... must be of type array`. `kiwix.yaml` had
    `syncOptions` as a YAML map (`{ CreateNamespace=true }`) rather than a list. Latent for a
    long time; only surfaced when the hard-refresh forced root-app to re-patch every child.

- **Bug 3 — monitoring app `Synced` but SealedSecret still not created.**
  - `argocd app get monitoring` showed all four resources, but the app's sync was *failing*:
    `one or more synchronization tasks are not valid`. The failing task was
    `homelab-rules.yaml`, a `PrometheusRule` (`monitoring.coreos.com/v1`) — a CRD that is **not
    installed**, because this stack uses the VictoriaMetrics operator (`VMRule`), not the
    Prometheus operator. One invalid resource failed the whole app's sync batch, taking the two
    SealedSecrets and the dashboard ConfigMap down with it.

- **Bug 4 — Grafana `CrashLoopBackOff` once the secret existed.**
  - `kubectl logs ... -c grafana --previous` showed
    `Failed to install plugin victoriametrics-datasource@: 404: Plugin not found`, fatal because
    `GF_PLUGINS_PREINSTALL_SYNC` makes a failed preinstall exit the process. The plugin coordinate
    404s on the registry. The VM datasource plugin is **not required** — VictoriaMetrics is
    Prometheus-API-compatible, so a plain `prometheus`-type datasource works fully.

- **Bug 5 — Grafana still `CrashLoopBackOff` after dropping the plugin.**
  - `--previous` log: `Datasource provisioning error: ... Only one datasource per organization
    can be marked as default`. The inline `datasources.yaml` (now active, after a typo fix —
    it had been misspelled `datasouces.yaml` and silently ignored) declared `isDefault: true`,
    and the chart's **datasources sidecar** (`sidecar.datasources.enabled: true`) was also
    provisioning a default datasource from a chart-created ConfigMap. Two defaults → fatal.
    `helm template ... | grep default` returned nothing, confirming the second default came from
    the sidecar discovering a ConfigMap at runtime, not from a rendered manifest.

- **Bug 6 — intermittent then constant port-forward `connection refused`.**
  - Presented as a flaky port-forward, not an obvious crash. `kubectl describe pod` →
    `Last State: Terminated, Reason: OOMKilled, Exit Code: 137`, `Restart Count: 5`. Grafana 13's
    embedded apiserver / unified storage exceeded the `256Mi` memory limit under dashboard-render
    load.

## Root cause
A chain, each masking the next:
1. **Orphaned directory** — `root-app` is non-recursive and no `k8s/apps/monitoring.yaml`
   Application existed, so nothing synced `k8s/apps/monitoring/`.
2. **Malformed `syncOptions`** in `kiwix.yaml` (map, not array) — held root-app `OutOfSync`.
3. **Wrong CRD kind** — `homelab-rules.yaml` was a `PrometheusRule`; the Prometheus-operator CRDs
   aren't installed (VM stack uses `VMRule`). One invalid resource failed the whole sync batch.
4. **Fatal plugin preinstall** — `GF_PLUGINS_PREINSTALL_SYNC` pulled a 404ing VM datasource plugin.
5. **Datasource `isDefault` collision** — inline datasource + datasources sidecar both default.
6. **OOMKill** — Grafana 13 over a `256Mi` limit.

## Fix
Declarative changes in `k8s/infrastructure/victoria-metrics.yaml` (Grafana block) and
`k8s/apps/`:

- Added `k8s/apps/monitoring.yaml` — an Application pointing at `k8s/apps/monitoring`, so the
  orphaned directory is synced.
- `k8s/apps/kiwix.yaml` — `syncOptions` rewritten as a list (`- CreateNamespace=true`).
- `k8s/apps/monitoring/homelab-rules.yaml` — converted `PrometheusRule`
  (`monitoring.coreos.com/v1`) → `VMRule` (`operator.victoriametrics.com/v1beta1`). Spec body
  unchanged; the `app.kubernetes.io/part-of: vm-k8s-stack` label kept so vmalert selects it.
- Grafana values: dropped the VM datasource plugin and provisioned a plain Prometheus datasource:
  ```yaml
  plugins: []
  extraEnvVars:
    GF_INSTALL_PLUGINS: ""
    GF_PLUGINS_PREINSTALL: ""
    GF_PLUGINS_PREINSTALL_SYNC: ""
  datasources:
    datasources.yaml:        # was misspelled "datasouces.yaml"
      apiVersion: 1
      datasources:
        - name: VictoriaMetrics
          type: prometheus
          access: proxy
          url: http://vmsingle-vm-victoria-metrics-k8s-stack.monitoring.svc:8428
          isDefault: true
  sidecar:
    datasources:
      enabled: false         # was true — collided with inline DS on isDefault
  ```
- Grafana memory limit `256Mi` → `512Mi` (request `96Mi` → `128Mi`).

## Verification
```bash
kubectl get pods -n monitoring                 # vm-grafana 2/2 Running, 0 restarts (sidecar dropped → 2 not 3)
kubectl get secret grafana-admin-creds -n monitoring   # exists
kubectl get vmrule -n monitoring               # homelab-rules present
kubectl describe pod -n monitoring -l app.kubernetes.io/name=grafana | grep -A4 'Last State'  # no OOMKilled after sustained use
# Grafana UI → Connections → Data sources → VictoriaMetrics → Test → green
# Bundled "Kubernetes / Views / *" + "Node Exporter Full" + "Homelab — Capacity" dashboards populate
```

## Prevention
- **Non-recursive app-of-apps silently drops subdirectories.** `root-app` only applies
  Application manifests directly under `k8s/apps/`. Any new service directory needs a matching
  top-level `<name>.yaml` Application, or its contents are invisible — with no error. When adding
  a directory under `k8s/apps/`, add the Application manifest in the same change. (Alternatively,
  enable `directory.recurse: true` on root-app — deliberately not done, to keep app boundaries explicit.)
- **One invalid resource fails the whole Application sync.** A single bad manifest (wrong CRD,
  schema error) blocks every other resource in that app. Validate CRD kinds against what's actually
  installed: this stack is VictoriaMetrics-operator (`VMRule`, `VMServiceScrape`, etc.), **not**
  prometheus-operator (`PrometheusRule`, `ServiceMonitor`).
- **The VM datasource plugin is not needed.** VictoriaMetrics speaks the Prometheus query API;
  provision a `type: prometheus` datasource against vmsingle. Avoids the registry-404 failure mode
  and the fatal `GF_PLUGINS_PREINSTALL_SYNC`.
- **Don't run the datasources sidecar alongside an inline-provisioned datasource** if both mark a
  default — pick one mechanism.
- **Grafana 13 needs >256Mi.** The OOM presented as flaky `port-forward connection refused`, not an
  obvious crash — always check `Last State` / `Reason` on `describe` before blaming the network.
- **Prefer `grafana.lan` (Traefik ingress) over `port-forward`** for day-to-day access; ingress
  reconnects across pod restarts, port-forward dies permanently on a blip.

## Related
- ADR: `docs/adr/005-victoria-metrics-monitoring.md` (datasource-type addendum added this session)
- Other lessons: `docs/lessons/k8s/grafana-pvc-corruption.md` (the persistence=emptyDir decision
  that made these restarts clean rather than corruption-prone)
- Chart docs: VictoriaMetrics k8s-stack — dashboards/datasource provisioning
