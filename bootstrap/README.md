# Bootstrap: the layer above Ansible, below ArgoCD

Three layers own this cluster, and this is the middle one.

| Layer | Owns | Mechanism |
|---|---|---|
| `ansible/` | the two VMs — journald, k3s config, systemd ordering | pull-on-demand playbook |
| `bootstrap/` | getting ArgoCD running and pointed at this repo | this script, run once per rebuild |
| `k8s/` | everything inside the cluster | ArgoCD, continuous, self-healing |

Only the third self-heals. This one runs once per rebuild and then never
again, which is exactly why it needed to stop being a list of commands to
copy out of a runbook.

## Files

| File | Purpose |
|---|---|
| bootstrap.sh | The sequence. Preflight, Sealed Secrets + master key, ArgoCD, the `argocd-cm` patch, repo credentials, `root-app`. Idempotent |
| versions.env | Every pin, plus the chart repo URLs. The one file to edit when bumping |
| argocd-cm-patch.yaml | The `resource.exclusions` ConfigMap patch that keeps `EndpointSlice` synced. Copied verbatim from the running cluster; re-diff after an ArgoCD upgrade |

## Usage

```bash
export MASTER_KEY=~/secure/sealed-secrets-master-key.yaml
export REPO_TOKEN='<gitea token, repo read scope>'

./bootstrap.sh --check    # preflight only, changes nothing
./bootstrap.sh
```

Idempotent. Every step checks for its own result first, so a run that dies
halfway can be re-run rather than unpicked.

## What it does

1. **Preflight** — kubectl/helm present, cluster reachable, all nodes Ready,
   and both secrets supplied. Fails here rather than halfway through.
2. **Sealed Secrets**, then restores the master key and restarts the
   controller. Before ArgoCD, always — see below.
3. **ArgoCD** at a pinned tag, then the `argocd-cm` exclusions patch, then a
   restart.
4. **Repo credentials** — the one Secret that can never be in git.
5. **`root-app`**, and the second `argocd-server` restart that everyone
   forgets.

## Two secrets, and why they aren't here

`MASTER_KEY` and `REPO_TOKEN` are passed in by the operator and are the only
things this layer cannot codify.

The master key is the trust root for every SealedSecret in `k8s/`; committing
it would make the entire sealing scheme decorative. The repo token is what
lets the cluster read the repo at all, so it cannot come from the repo. Both
live in the password manager. This is the discipline stated in
`cluster-rebuild.md` §0: if a secret isn't in the password manager, it isn't
real.

The script refuses to run without the master key rather than warning. That is
deliberate. Installing the controller without it lets the controller generate
a **fresh** keypair, at which point every SealedSecret in this repo is
encrypted against a key that no longer exists anywhere, and the only way out
is re-sealing all of them by hand. That failure is silent until apps start
failing to mount their secrets, which is much later and much more confusing.
Far better to stop at preflight.

## Ordering that is load-bearing

**Sealed Secrets before ArgoCD.** ArgoCD begins syncing the moment `root-app`
lands, and most apps have a SealedSecret they cannot start without.

**The `argocd-cm` patch before `root-app`.** It keeps `EndpointSlice` out of
ArgoCD's exclusion list. Miss it and the EndpointSlices pointing Traefik at
the LXC services (AMP, Proxmox, Technitium) are silently not synced — Traefik
answers "no available server" and nothing says why.

**The second `argocd-server` restart, after the sync settles.**
`argocd-cmd-params-cm` arrives via the `argocd-ingress` app and sets
`server.insecure=true`, but a ConfigMap change restarts nothing. Until that
restart, argocd-server stays in TLS mode and `argocd.lan` does not work. The
script waits for the ConfigMap and does it; if the sync is slow it tells you
to run it yourself rather than hanging.

## What writing this found

The runbook did not describe the cluster it was for. Three mismatches, all
found by diffing against the live cluster on 2026-07-27:

- **Sealed Secrets** was documented as `kubectl apply` of the upstream raw
  manifest. The live controller is a **Helm release** (chart 2.18.6). A
  rebuild would have produced a differently-shaped install than the one it
  was replacing.
- **MetalLB** was documented as `kubectl apply` of `metallb-native.yaml` from
  `main`, but the live install is the Helm chart via
  `k8s/infrastructure/metallb.yaml`, pinned and Synced. Following the runbook
  would have put a second, differently-shaped MetalLB in the same namespace
  for ArgoCD to fight with. **This step is now gone** — ArgoCD brings MetalLB
  up on its own, and nothing in the bootstrap path needs a LoadBalancer IP
  because ArgoCD is reached by port-forward until Traefik is up.
- **The `argocd-cm` patch** in the runbook carried a 5-entry exclusion list.
  ArgoCD 3.x's stock list has 7 — it added Cilium and Kyverno entries — so
  the old patch would have quietly reverted them. Neither is installed here,
  so nothing was broken, but `argocd-cm-patch.yaml` is now copied verbatim
  from the running cluster. Re-diff it after any ArgoCD upgrade.

Then committing the Sealed Secrets Application found a fourth, and the worst
of them: **the chart repo the live controller was installed from no longer
exists.** `https://bitnami-labs.github.io/sealed-secrets` returns a bare 404
— the project moved org on 2026-06-15 and GitHub Pages does not redirect
across org moves. The running controller neither knows nor cares, because it
was installed in May. A rebuild would have hit it cold.

That is the argument for this directory in one line. The URL had been dead
for six weeks, and nothing in a healthy cluster could have told you. Pinning
versions guards against surprise upgrades; it says nothing about whether the
host is still there.

None of these had caused an outage, because none had been exercised. That is
the point: an untested rebuild path is a claim, not a capability. This
script has been syntax- and dry-run-checked against the live cluster, but
**it has not been executed end-to-end against a bare cluster** — the only
honest test is a real rebuild, and the one thing worse than an untested
runbook is believing it's tested.

## Versions

All pins live in `versions.env`, read off the running cluster rather than
chosen. The previous runbook installed from `releases/latest`, `stable` and
`main` — three moving pointers, which meant two rebuilds a month apart would
produce two different clusters.

## What stays manual

Steps 1–3 of `cluster-rebuild.md`: Proxmox, the ZFS pool, the LXCs, VM
creation, and the k3s install itself. See `ansible/README.md` for why the
Proxmox layer is not codified. Longhorn's install is also still manual and
is tracked as known-risks item 6.
