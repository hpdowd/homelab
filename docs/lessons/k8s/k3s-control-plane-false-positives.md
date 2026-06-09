# Incident: ~12 false-positive alert emails/night — chart control-plane rules vs k3s

## Date
2026-06-09

## Time lost
~1h — the noise was obvious; the discipline was in proving the alerts were
wrong before silencing them, not just muting an inbox.

## Status
Resolved.

## Context
- **System / component:** `victoria-metrics-k8s-stack` (chart 0.81.0), namespace
  `monitoring`. The chart's bundled Kubernetes alert + recording rules, evaluated
  by vmalert and routed by Alertmanager.
- **Scope:** Alerting only — no workload was actually unhealthy. Pure signal noise.
- **State before:** The Alertmanager → Brevo SMTP relay had *just* started
  delivering (see the SMTP relay change in the same session). The moment email
  worked, a backlog of always-firing alerts that had been evaluating silently for
  weeks suddenly started landing in the inbox.

## Symptoms
- Roughly a dozen alert emails per night, every night, none corresponding to a
  real fault. The repeat-interval cadence (warnings 4h, criticals 1h) multiplied
  a handful of stuck alerts into ~12 deliveries.
- The alerts that were firing:
  ```text
  KubeControllerManagerDown
  KubeSchedulerDown
  3× "RecordingRuleNoData" for the kube-scheduler.rules group
  3× ScrapePoolHasNoTargets   (controller-manager, scheduler, proxy pools)
  ```
- Frequency: continuous — these never cleared, because the thing they describe
  never existed on this cluster.

## Investigation
The trap here is that "alert says component X is down" looks like a real outage.
The whole point of this entry is the chain that proved it was the *monitoring
assumption* that was wrong, not the component:

1. **Are the components actually alive?** Yes. `/healthz` on the k3s server
   returned ok, and the scheduler was visibly doing its job — pods scheduling
   onto `k3s-worker1` with normal `Scheduled` events. A genuinely-down scheduler
   would have left pods stuck `Pending`. So the "Down" alerts were lying.
2. **Why does the scrape think they're down?** Because there are no separate
   control-plane pods to scrape. k3s runs the apiserver, controller-manager,
   scheduler, and kube-proxy **in-process inside the single k3s server**, not as
   the discrete static pods a kubeadm cluster exposes. The chart ships
   ServiceMonitor/scrape definitions that target those non-existent endpoints.
3. **Confirm the scrape pools are empty.** The controller-manager, scheduler, and
   kube-proxy scrape pools were `0/0` targets up — `ScrapePoolHasNoTargets` is
   exactly the meta-alert that's supposed to catch this, and it was doing its job.
4. **Why the recording-rule no-data alerts?** The `kube-scheduler.rules` recording
   rules aggregate scheduler metrics that are never scraped, so they evaluate to
   no-data, and the no-data watchdog fires. Same root cause one layer up.
5. **Chain, end to end:** components alive → no separate control-plane pods
   (k3s in-process) → scrape pools `0/0 up` → recording rules no-data →
   `*Down` / no-data alerts fire as false positives.

## Root cause
The chart's bundled rules assume a kubeadm-style control plane where the
scheduler, controller-manager, etcd, and kube-proxy are **separately scrapable**
components. k3s embeds them in one process and does not expose those endpoints,
so the scrape targets are permanently empty and every rule that depends on them
fires or goes no-data. Nothing was broken — the monitoring stack was asserting a
topology this cluster doesn't have.

## Decision — disable, not rewrite
Two options:
- **Re-point the rules** at k3s's combined metrics endpoint so the existing
  alerts evaluate against real data.
- **Disable** the dead scrape jobs and their rule groups.

Chose **disable.** On a single-worker homelab there is no meaningful *separate*
control-plane signal to recover — the components are healthy or the whole node is,
and the node-level alerts (memory, OOM, disk, CrashLoop, Longhorn) in
`homelab-rules.yaml` already cover what actually bites. Rewriting the upstream
rules to chase k3s's combined endpoint is ongoing maintenance against every chart
bump, for a signal with no operational value here.

## Fix
Declarative, in the values block of `k8s/infrastructure/victoria-metrics.yaml`
(committed in `519d577`). Two layers — turn off the scrape jobs so there are no
empty pools, **and** turn off the rule groups so nothing evaluates against them:

```yaml
# scrape jobs off — no more 0/0 target pools, no ScrapePoolHasNoTargets
kubeControllerManager: { enabled: false }
kubeScheduler:         { enabled: false }
kubeEtcd:              { enabled: false }   # k3s defaults to embedded SQLite, not etcd
kubeProxy:             { enabled: false }

defaultRules:
  enabled: true                              # global rules stay ON
  groups:                                    # only the dead groups off
    kubernetesSystemControllerManager: { enabled: false }
    kubernetesSystemScheduler:         { enabled: false }
    kubeScheduler:                     { enabled: false }
    etcd:                              { enabled: false }
```

`homelab-rules.yaml` (the hand-written `VMRule`) was **not** touched — only the
chart's bundled control-plane rules were disabled.

Two latent bugs were fixed in the same pass, both of which had been silently
defeating the config (see the companion lesson on silent ArgoCD `ComparisonError`):
- a **duplicate `defaultRules:` block** — YAML last-wins was discarding the real one;
- a **`kubeControlManager` typo** (missing "ler") — an unknown Helm key, silently
  ignored, so the controller-manager scrape was never actually disabled.

## What we deliberately did *not* do
This was a targeted silence, not a blanket mute of the inbox:
- **kube-proxy was checked, not assumed.** Its scrape pool was confirmed `0/0`
  (k3s binds proxy metrics to localhost, not a cluster-scrapable endpoint) before
  disabling it. There is no default kube-proxy *alert* group to disable, so only
  the scrape toggle was needed.
- **The no-data / `ScrapePoolHasNoTargets` watchdog was kept on.** That meta-alert
  is the thing that would tell us a *real* scrape pool went empty in future —
  silencing it would have been silencing the smoke detector. Only the specific
  dead groups were disabled; the watchdog family stays armed.
- **The `etcd` group was disabled preventatively, for scrape consistency** — k3s
  defaults to embedded SQLite (kine), so there's no etcd endpoint to scrape. No
  etcd alert was actually *firing*; it was turned off alongside its (also-empty)
  scrape job so the two stay coherent, not in response to noise.

## Verification
Verified live after sync (Synced / Healthy):
```bash
argocd app get victoria-metrics            # Synced, Healthy
kubectl get vmalert -n monitoring          # rules reloaded
# Alertmanager UI / inbox: firing alerts down to the three expected
# steady-state homelab alerts; the Kube*Down / no-data / ScrapePool noise gone.
```
> Note: the precise group-key → alert-name mapping (which bundled rule lives in
> which `defaultRules.groups` key) is upstream kubernetes-mixin convention. The
> group keys are schema-confirmed against `helm show values … --version 0.81.0`;
> the mapping was confirmed *empirically* here — the listed alerts stopped firing
> after the matching groups were disabled. If you need certainty for a future
> edit, `kubectl get vmrule -n monitoring -o yaml` shows the rendered groups.

## Prevention
- **Verify the alert before silencing it.** "Component X down" is a hypothesis,
  not a fact — check the component is actually alive (`/healthz`, real activity)
  before deciding whether to fix the component or fix the rule. Muting a *true*
  alert is how outages get missed.
- **k3s ≠ kubeadm for control-plane scraping.** Any chart written for a standard
  control plane will ship dead scrape jobs and rules for scheduler /
  controller-manager / etcd / kube-proxy on k3s. Expect to disable that family on
  every monitoring chart, not just this one.
- **Silence narrowly, keep the watchdogs.** Disable the specific dead groups, not
  the `ScrapePoolHasNoTargets` / no-data meta-alerts that would catch the next
  *real* empty pool.
- **An empty inbox hides always-firing alerts.** These had been evaluating for
  weeks; only a working relay surfaced them. When you first wire up alert
  delivery, expect a backlog of latent always-on alerts to flush — triage them,
  don't reflex-mute.

## Related
- ADR: `docs/adr/005-victoria-metrics-monitoring.md` (monitoring design; SMTP-relay addendum)
- Other lessons:
  - `docs/lessons/k8s/argocd-comparisonerror-silent-values.md` — the duplicate
    `defaultRules` / typo that silently defeated this config (same session)
  - `docs/lessons/k8s/grafana-monitoring-sync-cascade.md` — the broader monitoring
    bring-up cascade
- Upstream: VictoriaMetrics `victoria-metrics-k8s-stack` values — `defaultRules.groups`
  and per-component `kube*` scrape toggles
