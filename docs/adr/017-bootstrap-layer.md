# ADR 017: A `bootstrap/` layer, as a shell script rather than a runbook section

**Status:** Accepted
**Date:** 2026-07-27
**Superseded By:** None

## What problem this solves

Getting from "two k3s VMs exist" to "ArgoCD is reconciling this repo" was ten
imperative steps in `cluster-rebuild.md` §4–6, to be copied out by hand in the
right order. Everything above that line is ArgoCD's and self-heals, everything
below it is `ansible/` and at least has a role that can be re-run, but the seam
between them was prose and nothing else.

Prose was tolerable while it was only tedious. It stopped being tolerable when I
went to codify it and found that it did not describe this cluster. Three
mismatches, none of which had ever caused a problem because none had ever been
exercised: Sealed Secrets was documented as `kubectl apply` of the upstream raw
manifest when the live controller is a Helm release; MetalLB was documented as
`kubectl apply` of `metallb-native.yaml` from `main` when the live install is
the Helm chart ArgoCD already manages, so following the runbook would have put
two differently-shaped MetalLBs in one namespace for ArgoCD to fight with; and
the `argocd-cm` exclusions patch carried a five-entry list when ArgoCD 3.x's
stock list has seven, so applying it would have quietly reverted the Cilium and
Kyverno entries.

Worse, three of the installs pulled from moving upstream pointers —
`releases/latest`, `stable`, and `main`. Two rebuilds a month apart would
install two different clusters, and the whole point of a rebuild runbook is that
it puts back what was there.

So the bootstrap is now `bootstrap/bootstrap.sh`, with every pin in
`versions.env` read off the running cluster rather than chosen, and the
`argocd-cm` patch as a reviewable file instead of an `\n`-escaped YAML string
embedded in a `kubectl patch` argument. `cluster-rebuild.md` §4 points at it.

## What I rejected

**Leaving it as runbook prose and just correcting it.** This was the cheap
option and I nearly took it, because the three errors above are each a one-line
fix. I rejected it because correctness was never the binding problem. The
runbook had been wrong for an unknown number of weeks and nothing surfaced it;
a corrected runbook has exactly the same property, and I would be relying on the
next correction happening the same way this one did, which is to say by
accident. A script at least fails loudly, and its preflight can assert things
prose can only ask you to remember.

**Ansible, extending the layer that already exists.** Superficially attractive,
since `ansible/` is right there and already owns the node layer. I rejected it
because the two are different shapes of problem. Ansible converges declared
state on hosts and is at its best when re-run indefinitely; the bootstrap is a
*once-per-rebuild ordered sequence* of API calls where the ordering is the
content — Sealed Secrets strictly before ArgoCD, the `argocd-cm` patch strictly
before `root-app`, the second `argocd-server` restart strictly after the sync
settles. Expressing that as roles and handlers would mean fighting Ansible's
model to describe a linear script, and the `kubernetes.core` modules would add a
collection dependency and a Python environment on the control node in exchange
for wrapping calls that `kubectl` already makes plainly.

**Terraform against the Kubernetes provider.** Rejected on state. A once-run
sequence would acquire a state file that has to live somewhere durable, and the
only durable thing here is the cluster this script exists to create. That is a
circle I am not going to close for a script that runs a handful of times in the
lifetime of the box. The same reasoning that keeps Proxmox out of Terraform in
`ansible/README.md` applies with more force.

**Making it an ArgoCD Application.** Not possible, and worth writing down so
nobody re-derives it: this is the thing that installs ArgoCD.

## Consequences

Two secrets stay operator-supplied and cannot be otherwise. The Sealed Secrets
master key is the trust root for every `SealedSecret` in `k8s/`, so committing
it would make the whole sealing scheme decorative, and the repo credential is
what lets the cluster read the repo, so it cannot come from the repo. Both live
in the password manager, which is the discipline `cluster-rebuild.md` §0 already
states. The script refuses to start without the master key rather than warning,
because a controller installed without it silently generates a fresh keypair and
the failure only surfaces much later as apps failing to mount secrets.

The Sealed Secrets chart version is now pinned in two places —
`bootstrap/versions.env` and `k8s/infrastructure/sealed-secrets.yaml` — because
bootstrap installs the controller before ArgoCD exists and the Application
declares it afterwards. This breaks the repo's "state a version once" rule and I
could not find a way around it that was not worse. Both files carry a warning to
bump them together.

Declaring Sealed Secrets at all was a second decision folded into this one. It
had no declarative source anywhere before: not in `k8s/`, not in `ansible/`, and
described wrongly in the runbook. It follows `longhorn.yaml`'s pattern of an
Application deliberately without `syncPolicy.automated`, so committing it
creates the object and nothing reaches the cluster until someone syncs on
purpose. ArgoCD reports it `Synced` without ever having been synced, which is
the useful confirmation that the declaration reproduces the hand-install exactly.

**The script has not been run end-to-end.** It is syntax-checked, and its two
riskiest `kubectl` invocations were dry-run against the live cluster — the
`argocd-cm` patch is a no-op there, which is the correct result — but the only
honest test is a real rebuild against a bare cluster, tracked as known-risks
item 11. This ADR records a better-documented bootstrap, not a proven one, and
the distinction is the entire lesson of the day it was written.
