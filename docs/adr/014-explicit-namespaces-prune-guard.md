# ADR 014: Explicit per-app namespaces, guarded against an ArgoCD prune-cascade

**Status:** Accepted
**Date:** 2026-07-22
**Superseded By:** None

## What problem this solves

Namespaces were created two different ways depending on which app I'd written
last. Six apps carried a `namespace.yaml` in their directory; the rest leaned on
`CreateNamespace=true` in the Application's `syncOptions` and let ArgoCD conjure a
bare namespace on first sync. Neither was wrong, but the split meant a namespace's
existence was sometimes a declared object I could label and sometimes an invisible
side-effect of a sync flag, and I could never remember which without going and
looking.

I settled it the obvious way — every app declares its own `namespace.yaml`, and
`CreateNamespace=true` is gone. A declared namespace is a real object I can hang
PodSecurity labels, quotas, and NetworkPolicy selectors off later (ADR 011's
default-deny netpols already want namespace labels), it shows up in `git grep`,
and deleting an app directory prunes the namespace and its contents as one unit
instead of orphaning it.

But making the namespace a managed object is exactly what creates a new way to
lose data, and that is the real reason this is written down rather than left as a
one-line commit.

## The failure mode I'm defending against

Once ArgoCD manages a namespace under `automated: { prune: true }`, the namespace
is prunable. If the `namespace.yaml` ever disappears from the repo or gets
mis-pathed — a bad rebase, a fat-fingered `git mv`, a refactor that moves the
directory — ArgoCD sees a managed resource that no longer has a source and deletes
it. Namespace deletion cascades in Kubernetes: it takes every object inside with
it, PVCs included, and the Longhorn StorageClass runs the default
`reclaimPolicy: Delete`, so a deleted PVC deletes the underlying volume and its
data. The whole chain — vanished manifest → pruned namespace → deleted PVC →
destroyed volume — runs on its own with no confirmation, driven by `selfHeal`
reconciling toward a git state I never meant to write.

Under the old `CreateNamespace=true` this couldn't happen: the namespace was never
a managed resource, so it was never a prune candidate. So the convention change is
a straight trade — I gained declarability and consistency and took on a
prune-cascade risk that wasn't there before.

## What I picked

Keep the explicit-namespace convention, and close the new risk at its source with
`argocd.argoproj.io/sync-options: Prune=false` on the objects whose loss is
unrecoverable:

- **Namespaces:** `nextcloud`, `immich`, `gitea`. ArgoCD will apply them and heal
  drift, but will never prune them, so a missing manifest can't fire the cascade.
- **The irreplaceable PVCs inside them:** `nextcloud-data`, `nextcloud-db`,
  `immich-library`, `immich-db`, `gitea-data`. Belt to the namespace's braces —
  even a delete aimed straight at a PVC resource is refused.

Deleting any of these now has to be a deliberate `kubectl delete` by hand, which is
the correct amount of friction for a volume holding photos, files, or Git history.

This is **Layer 1** of a defence-in-depth I'm building deliberately, and it sits on
top of what already exists: restic→B2 offsite (ADR 004) and the per-app backup
CronJobs for gitea, nextcloud, and immich. Layer 1 stops the accident; the backups
catch what Layer 1 can't (theft, fire, a genuine `kubectl delete` I meant at the
time and regret later).

## What's deliberately *not* guarded

- **argocd** stays the one namespace with no `namespace.yaml` and no
  `CreateNamespace`. It has to pre-exist for ArgoCD to run at all — you can't
  bootstrap the controller from its own Application — so "self-contained,
  prune-managed" is a category error there. It was already a documented exception
  and it stays one.
- **kiwix** is Longhorn-backed but holds re-downloadable ZIM files, not data I
  create. Losing it costs bandwidth and an afternoon, not something irreplaceable,
  so it's left prunable on purpose. Same reasoning skips the two reproducible
  caches: `immich-ml` (model downloads, on local-path) and the gitea act-runner
  PVC (CI scratch).

## Layer 2, considered and deferred: `reclaimPolicy: Retain`

The stronger backstop is a Longhorn StorageClass with `reclaimPolicy: Retain`, so
that even a *manual* PVC delete leaves the volume intact and the data recoverable
by re-binding it. I'm not doing it yet, on purpose, because I want to understand
the ongoing cost before I take it on. For the record, the maintenance it adds:

- **Every deleted PVC leaves an orphaned `Released` PV behind.** With `Delete` the
  volume goes when the claim goes and I never think about it. With `Retain` the PV
  outlives the claim in `Released` state and does not automatically accept a new
  one — I have to find it, clear its `claimRef`, and manually re-bind or delete it.
  Storage that used to clean itself up now needs a human in the loop each time.
- **Recovery is a manual dance, not a feature.** "The data survived" and "the app
  is back" are different steps: I still have to locate the retained PV, wipe its
  `claimRef.uid`, and point a fresh PVC at it by name. Worth practising *before*
  I'm relying on it in anger.
- **Silent capacity creep.** Orphaned `Released` PVs keep occupying Longhorn space
  until I reap them by hand, so on a box where capacity and RAM are already the
  binding constraints (ADR 012), Retain quietly works against the thing I'm most
  short of unless I stay disciplined about cleanup.
- **It's a cluster-level change, not a repo one.** It means a second StorageClass
  (`longhorn` is shared; I don't want Retain on *everything*) and migrating the
  data PVCs onto it — real surgery on live volumes, versus Layer 1 which is eight
  annotations and a sync.

Given Layer 1 already blocks the accidental path and the intentional-delete path is
rare and deliberate, Retain buys a narrow slice of extra safety for a standing
maintenance tax. Revisit it if I ever actually fat-finger a data PVC and Layer 1's
`Prune=false` turns out to have a gap, or when a restore drill shows restic→B2 is a
slower RTO than I'm willing to wear for the photo library.

## What would change the answer

- **A near-miss.** If a real incident gets past Layer 1 — some prune path I didn't
  anticipate — that's the day Layer 2 stops being optional.
- **A tested restore that's too slow.** If a B2 restore of immich or nextcloud
  turns out to be an RTO I can't live with, `Retain` (fast local re-bind) earns its
  keep as the quick path, with restic as the disaster floor beneath it.
- **More stateful apps.** vaultwarden (in flight) and anything after it should get
  the same Layer-1 treatment as part of standing them up, not bolted on later.

## Related

- ADR 004 — restic→B2 offsite backup. The backstop under all of this; Layer 1
  prevents the accident, ADR 004 catches everything prevention can't.
- ADR 011 — the per-namespace NetworkPolicy/PodSecurity baseline that explicit,
  labelable namespaces make cleaner to extend.
- ADR 012 — the RAM-and-capacity constraint that makes Layer 2's orphan-PV creep a
  real cost rather than a footnote.
- HOMELAB.md — the app inventory and which namespaces hold irreplaceable state.
