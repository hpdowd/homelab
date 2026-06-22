# Incident: Alertmanager null-route typo + route ordering, Watchdog/InfoInhibitor leaked to email

## Date
2026-06-09

## Time lost
~30m; the typos were silent (config still loaded, alerts still flowed); the
tell was `Watchdog` landing in the inbox, which should never be deliverable.

## Status
Resolved.

## Context
- **System / component:** `victoria-metrics-k8s-stack` (chart 0.81.0), namespace
  `monitoring`. The inline `alertmanager.config` block in
  `k8s/infrastructure/victoria-metrics.yaml`, route tree + inhibit rules.
- **Scope:** Alert *routing* only. No workload affected; this is about which
  alerts reach email, not whether anything was unhealthy.
- **State before:** Same session the Brevo SMTP relay first started delivering
  (see the SMTP-relay addendum in ADR 005 and the control-plane false-positives
  lesson). With email finally working, the Watchdog leak became visible; the
  inhibit-rule defect was found by reading the config in the same pass, not from
  inbox volume.

## Symptoms
- `Watchdog`, the always-firing dead-man's-switch alert, was being **delivered
  to email**. It exists only to prove the pipeline is alive and must be
  black-holed, never sent. This was the observed tell, and it was continuous
  (Watchdog fires every cycle).
- On inspection of the config (not from observed inbox volume), the
  `InfoInhibitor` inhibit rule was also dead, so lone `info`-severity alerts had
  nothing suppressing them; a latent defect rather than something that had
  visibly flooded the inbox.

## Investigation
The config *looked* correct at a glance, there was a `"null"` receiver, a route
that matched `Watchdog|InfoInhibitor`, and an inhibit rule for info alerts. The
bugs were all single-character / ordering mistakes that YAML and the operator
accept without complaint:

1. **Why is Watchdog reaching email?** The route meant to drop it read
   `- reciever: "null"`, `receiver` misspelled. A route with no *recognised*
   `receiver` key does not get the `"null"` receiver; per Alertmanager semantics a
   route that omits `receiver` **inherits its parent's**, and the parent route's
   receiver is `email`. So Watchdog/InfoInhibitor matched the route by `alertname`
   but were then routed straight to email anyway.
2. **Does route *order* matter here too?** Alertmanager evaluates sibling routes
   top-to-bottom and stops at the **first match** (no `continue`). The drop route
   was listed *after* the `severity = "critical"` route. For these specific alerts
   it's not the live trigger (Watchdog isn't critical, so it skips the critical
   route anyway), but a silence/drop route belonging *below* other routes is fragile,
   any future route that also matched would win first. The fix moves it to the
   top so noise is dropped before the tree does anything else.
3. **Why isn't InfoInhibitor inhibiting?** The inhibit rule's source matcher read
   `alertname = "InforInhibitor"`, an extra "r". No alert by that name exists
   (the real one is `InfoInhibitor`), so the source set was always empty and the
   inhibition never activated.

## Root cause
Three independent typo/ordering defects in the inline Alertmanager config, none
of which produce a load error: so the stack ran, alerts flowed, and the only
signal was wrong-looking email:
- `reciever:` → route silently inherits the parent `email` receiver instead of
  black-holing Watchdog/InfoInhibitor.
- Drop route ordered after the critical route instead of first.
- `InforInhibitor` → an inhibit source matcher that matches nothing, so lone
  info alerts are never suppressed.

## Fix
Declarative, in the `alertmanager.config` block of
`k8s/infrastructure/victoria-metrics.yaml` (committed in `0b0cf4d`):

```yaml
route:
  receiver: "email"
  routes:
    # drop route FIRST — silence before the tree routes anything else
    - receiver: "null"                 # was: reciever: "null" (inherited email)
      matchers:
        - alertname =~ "Watchdog|InfoInhibitor"
    - receiver: "email"
      matchers:
        - severity = "critical"
      repeat_interval: 1h

inhibit_rules:
  - source_matchers: [alertname = "InfoInhibitor"]   # was: "InforInhibitor"
    target_matchers: [severity = "info"]
    equal: ["namespace"]
```

## Verification
```bash
argocd app get victoria-metrics      # Synced / Healthy after the change
# Inbox: Watchdog no longer delivered; lone info alerts no longer arrive
# unless a warning/critical is firing in the same namespace.
```
To prove the *rendered* config (not just the source) is correct, dump the secret
the operator generates and confirm the receiver/inhibit names:
```bash
kubectl get secret -n monitoring -l app.kubernetes.io/instance=vm \
  -o name | grep alertmanager
# then base64 -d the config key and check receiver: "null" / InfoInhibitor
```

## Prevention
- **A silent config is the dangerous one.** None of these three bugs failed the
  YAML parse, the operator render, or Alertmanager startup. The only way to catch
  them is to test the *behaviour*: send a Watchdog and confirm it does **not**
  arrive; confirm a lone info alert is suppressed. "Config applied cleanly" ≠
  "config does what it says."
- **A misspelt `receiver` key doesn't error: it inherits.** Unknown keys are
  silently dropped; the route falls back to the parent receiver. Same trap class
  as the `kubeControlManager` typo in the companion lessons.
- **Put silence/null routes first.** First-match-wins means a drop route only
  reliably drops if nothing above it can claim the alert.
- **`Watchdog` in the inbox is itself the alert.** If the dead-man's-switch ever
  gets delivered, the routing is broken, treat it as a routing smoke test, not
  just noise to mute.

## Related
- ADR: `docs/adr/005-victoria-metrics-monitoring.md` (monitoring design; SMTP-relay addendum)
- Other lessons:
  - `docs/lessons/k8s/k3s-control-plane-false-positives.md`, the chart-rule
    noise that flushed the same session a working relay surfaced it
  - `docs/lessons/k8s/argocd-comparisonerror-silent-values.md`, same family of
    silent typo/duplicate-key config defects that apply but never take effect
  - `docs/lessons/k8s/grafana-monitoring-sync-cascade.md`, the broader monitoring
    bring-up cascade
- Upstream: Alertmanager routing (`receiver` inheritance, first-match) and
  `InfoInhibitor` inhibit-rule convention (kube-prometheus)
