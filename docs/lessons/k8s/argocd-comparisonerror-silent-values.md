# Incident: Silent ArgoCD ComparisonError, bad inline Helm values, no surface symptom

## Date
2026-06-09  <!-- recurring; first bit during the monitoring bring-up, again on the control-plane cleanup -->

## Time lost
~Cumulative across several sessions, each instance cost time mostly because
*nothing looked wrong*: workloads kept running, no pod crashed, no alert fired.

## Status
Resolved (pattern documented; this is a recurring gotcha, not a one-off).

## Context
- **System / component:** ArgoCD Applications that carry a chart's config as an
  **inline Helm values block:** chiefly
  `k8s/infrastructure/victoria-metrics.yaml` (`spec.source.helm.values: |`).
- **Scope:** A single Application's sync. The live cluster is unaffected; it
  keeps running the *last successfully rendered* spec.
- **State before:** Routine edits to the inline values block, adding a field,
  toggling a component, restructuring a section.

## Symptoms
The defining symptom is the **absence** of one:
- The Application goes to **`Unknown`** sync status with a **`ComparisonError`**
  in its conditions, ArgoCD couldn't run `helm template` to render the desired
  state, so it has nothing to diff against and refuses to sync.
- **Live workloads keep running on the old spec.** No pod restarts, no
  CrashLoop, no alert. If you only watch the cluster, everything looks fine.
- The change you committed simply **never takes effect**, indefinitely, with no
  error surfaced anywhere you'd normally look.
  ```text
  ComparisonError: `helm template .` failed exit status 1:
    Error: YAML parse error on .../values.yaml: ...
  # or, no error at all — a duplicate key parses fine and silently last-wins
  ```

Two concrete instances seen on this repo:
1. **`extraArgs` nested under `resources`.** A wrong indent level put
   `extraArgs` inside the `resources:` map. Sometimes a render error; sometimes
   it just lands as dead config the chart never reads.
2. **Duplicate `defaultRules:` block.** Two `defaultRules:` keys in the same
   values map. YAML doesn't error on duplicate keys, **last-wins**, so the
   real, carefully-written block was silently discarded by an empty/placeholder
   one later in the file. The intended rule-group disables never applied.

A close cousin: **unknown Helm keys are silently ignored.** A `kubeControlManager`
typo (for `kubeControllerManager`) doesn't error, Helm just drops the key, so
the toggle does nothing and you think it's set.

## Investigation
- Cluster-side checks all came back healthy, which is the whole problem; it
  sends you looking in the wrong place.
- The signal lives in **ArgoCD**, not the cluster:
  ```bash
  argocd app get victoria-metrics            # Sync Status: Unknown; look at Conditions
  argocd app get victoria-metrics -o json | jq '.status.conditions'
  ```
- For the silent (no-error) class (duplicate keys, ignored unknown keys), even
  ArgoCD looks green. The only reliable check is to **render the values yourself**
  and read the output:
  ```bash
  # what does Helm actually produce from this values block?
  helm template vm vm/victoria-metrics-k8s-stack --version 0.81.0 -f <(values) | less
  ```

## Root cause
The inline `values: |` is a **YAML block scalar, opaque to ArgoCD's outer
parse.** The outer Application manifest validates fine regardless of what's
inside the string; the inner YAML is only parsed later, by Helm, at render time.
So an indentation or duplicate-key mistake inside the block:
- isn't caught by the outer manifest validation,
- doesn't crash any running pod,
- and surfaces only as an ArgoCD `ComparisonError` (render failure), or not at
  all, when YAML last-wins / Helm's ignore-unknown-keys swallow it.

The failure mode is **silent drift**: git says one thing, the cluster runs
another, and nothing connects the two.

## Fix
No single command, the fix is a habit. For the instances above:
- moved `extraArgs` out to the correct indent level (sibling of `resources`);
- removed the duplicate `defaultRules:` block, keeping the real one;
- corrected the `kubeControlManager` → `kubeControllerManager` key.
All in `k8s/infrastructure/victoria-metrics.yaml`.

## Verification
```bash
argocd app get victoria-metrics            # Sync Status: Synced (not Unknown), Healthy
# and prove the change actually rendered, not just that sync is green:
kubectl get vmsingle vm-victoria-metrics-k8s-stack -n monitoring -o yaml | grep -A2 extraArgs
kubectl get vmrule -n monitoring -o yaml   # the intended rule groups present/absent as edited
```

## Prevention
- **After editing an inline values block, check ArgoCD sync status, not just the
  pods.** `Unknown` + `ComparisonError` is the tell. Healthy pods prove nothing;
  they may be running the pre-edit spec.
- **Render before you commit** when the change is non-trivial:
  `helm template … -f values | …`. Catches parse errors and duplicate-key
  last-wins that ArgoCD won't flag.
- **Watch for duplicate top-level keys.** YAML silently last-wins; a stray second
  `defaultRules:` / `grafana:` / `vmsingle:` discards the other. A linter with
  duplicate-key detection (`yamllint`) on the *extracted* values block catches it.
- **Unknown Helm keys are silently dropped:** a typo'd key is a no-op, not an
  error. When a toggle "isn't working," suspect the key name, and confirm it
  against `helm show values <chart> --version <pinned>`.
- **Prefer the smallest correct edit.** The block scalar's lack of outer
  validation is exactly why large restructures of inline values are risky,
  small diffs are easier to render-check and eyeball for indent drift.

## Related
- Other lessons:
  - `docs/lessons/k8s/k3s-control-plane-false-positives.md`, the config the
    duplicate `defaultRules` / typo were silently defeating
  - `docs/lessons/k8s/grafana-monitoring-sync-cascade.md`, another silent-sync
    class (one bad CRD kind fails a whole Application's sync batch)
- ADR: `docs/adr/005-victoria-metrics-monitoring.md`
