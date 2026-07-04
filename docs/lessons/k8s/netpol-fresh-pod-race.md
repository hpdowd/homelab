# Incident: default-deny NetworkPolicy raced kube-router's fresh-pod registration, broke nextcloud-cron

## Date
2026-07-03

## Time lost
~1h, during the ADR 011 workload-hardening rollout. No user-facing outage —
Nextcloud itself stayed up throughout; the casualty was the background cron and,
had it not been caught, the nightly DB backups.

## Status
Resolved — the `immich` and `nextcloud` NetworkPolicies were reverted; the
securityContext hardening in the same pass was kept. Re-adding them needs the
wait-guard in Prevention.

## Context
- **System / component:** `nextcloud` (and by extension `immich`) namespaces,
  the default-deny-ingress NetworkPolicies added in ADR 011.
- **Scope:** short-lived pods only — `nextcloud-cron` (every 5 min) and the
  nightly `pg_dump` backup CronJobs. Long-lived pods were unaffected.
- **State before:** phase 4 of the hardening pass had just applied
  `nextcloud/networkpolicy.yaml` (default-deny ingress, allow same-namespace +
  `:80` from the pod CIDR). Pods Ready, app serving.

## Symptoms
`nextcloud-cron` Jobs going to `Failed`, their pods `Error`:

```text
Failed to connect to the database: SQLSTATE[08006] connection to server at
"postgres" (10.43.42.230), port 5432 failed: Connection refused
```

But `php occ status` run *inside the live nextcloud pod* reached the same DB
fine (`installed: true`). So the app pod → postgres worked while fresh cron pods
→ postgres were refused, same namespace, same Service, same port. DNS was not the
problem — the error shows the name already resolved to the ClusterIP.

## Investigation
- **Dead end:** first assumed the transient postgres `Recreate` window from
  phase 5 (postgres was briefly down mid-roll). Ruled out — Job `29718465` ran
  and `Failed` *after* postgres was back `accepting connections`, and `29718470`
  kept failing minutes later.
- `occ status` from the app pod worked → the netpol's same-namespace rule
  (`from: podSelector: {}`) *does* allow same-ns → postgres for an established
  pod. So the rule isn't wrong; the difference is the pod.
- Only variable left: pod age. Confirmed it directly with a probe pod in the
  `immich` namespace that connects immediately, then again after a delay:

  ```text
  == t0  (immediate) ==  postgres...:5432 - no response        rc=2
  == t14 (after 14s) ==  postgres...:5432 - accepting connections  rc=0
  ```

  Same pod, same target — blocked at t=0, allowed at t=14s.

## Root cause
k3s enforces NetworkPolicy with **kube-router**, which maintains the set of
source pod IPs a `podSelector` rule matches as an ipset, updated *after* a pod
starts. There is a several-second window where a just-created pod's IP is not yet
in its own namespace's source-set. A short-lived pod that connects to a
same-namespace service inside that window is not matched by the
`from: podSelector: {}` rule, falls through to the only other ingress rule (pod
CIDR → `:80`), and its `:5432`/`:6379` connection is **rejected** (kube-router
REJECTs, hence "connection refused" rather than a timeout).

`nextcloud-cron` runs `php cron.php`, which opens the DB connection at t≈0 → it
loses the race almost every time. The long-lived app pod was registered seconds
after *its* start and has been fine ever since, which is why the two disagreed.
`immich-backup` would hit the same race, but its `pg_dump` runs only after an
`apk add restic` (several seconds) — likely enough delay to win, but "likely" is
not acceptable for the sole offsite DB backup, and its dump has no retry.

## Fix
Reverted the two racing netpols; kept everything else in the pass.

```bash
git rm k8s/apps/nextcloud/networkpolicy.yaml   # commit 66e20a9
git rm k8s/apps/immich/networkpolicy.yaml      # commit 7f29ebf
```

The five netpols with **no** short-lived same-namespace pod hitting a protected
port were kept and stand: `portfolio`, `kiwix`, `collabora`, `file-parser`
(strict), `gitea` (its backup only talks to the kube API + PVC; the act-runner
it fronts is long-lived).

## Verification
```bash
# Manually triggered cron completes now that the netpol is gone
kubectl -n nextcloud create job --from=cronjob/nextcloud-cron ncron-check
kubectl -n nextcloud wait --for=condition=complete job/ncron-check --timeout=90s   # met, ~4s
# CronJob resumed clean scheduled runs
kubectl -n nextcloud get cronjob nextcloud-cron -o jsonpath='{.status.lastSuccessfulTime}'
```

## Prevention
- **Re-add the DB-isolation netpols only with a wait-guard on the short-lived
  pods** so they don't connect inside the registration window — e.g. prepend
  `until pg_isready -h postgres -t 2; do sleep 2; done` to the cron and backup
  scripts (also makes them robust to postgres being briefly down for any reason).
  Then `immich`/`nextcloud` get default-deny back cleanly.
- **A namespace is only safe for a default-deny-ingress netpol if no short-lived
  pod in it connects to a same-namespace protected port in its first seconds.**
  Check for CronJobs before adding one.
- Remember on this cluster kube-router **REJECTs** denied traffic (`connection
  refused`), it doesn't drop it (no hang) — a fast "connection refused" to a
  service you know is up is a netpol signature, not a dead backend.

## Related
- ADR 011 — the hardening pass this was a consequence of (carve-out 2).
- `docs/lessons/k8s/argocd-selfheal-backup-race.md` — the other "looked fine,
  wasn't" backup-integrity near-miss in the same namespace family.
- `docs/reference/gotchas.md` — NetworkPolicy section.
