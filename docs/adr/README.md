# Architecture Decision Records

Short documents capturing *why* a decision was made: what was considered, what was rejected, and why the chosen approach won. Written after the fact, kept as permanent record.

Each ADR has a **Status** (Accepted / Superseded) and a **Superseded By** line so reversed decisions show their evolution rather than being silently rewritten.

| File | Decision |
|---|---|
| 004-restic-b2-bckup.md | Offsite backup with restic to Backblaze B2 |
| 005-victoria-metrics-monitoring.md | VictoriaMetrics single-node over kube-prometheus-stack |
| 006-immich.md | Immich: public before Authelia, raw manifests, 100MB tunnel cap accepted, backed up from day one |
| 007-certmanager-wildcard-tls.md | cert-manager + Let's Encrypt DNS-01 wildcard as Traefik's default cert — fixes self-signed TLS on the split-horizon LAN path |
| 008-gitea-actions.md | Gitea Actions: in-cluster act_runner (DinD) for manifest CI; heavy builds (Android) offloaded to GitHub-hosted runners — worker RAM can't host them (runner model superseded by 010) |
| 009-portfolio.md | Portfolio site: one static Go binary, GHCR image built by GitHub Actions, self-monitored on the apex; no secret on the public-facing pod |
| 010-act-runner-host-executor.md | act_runner moved to the host executor — drops the privileged DinD sidecar; jobs run daemonless in the runner pod (supersedes 008's runner model) |
| 011-workload-securitycontext-networkpolicy.md | Per-image securityContext baseline (drop all caps, add back only what each entrypoint needs — not blanket `runAsNonRoot`) on 9 workloads + default-deny-ingress NetworkPolicies on 5 namespaces. Two carve-outs: immich-ml hangs under the profile, and the immich/nextcloud netpols race kube-router's fresh-pod registration |
| 012-keep-zfs-mirror-over-longhorn-redundancy.md | Keep the 2×2TB ZFS mirror; reject breaking it into single-disk pools + Longhorn `replica=2`. The mirror uniformly protects off-cluster DNS/VPN that Longhorn can't replicate; `replica=2` spends the binding RAM constraint, doubles HDD/iSCSI writes, loses ZFS self-heal, and the capacity gain is illusory (replica=2 still costs 2×). Add a 3rd drive for bulk instead |

Numbering starts at 004: decisions 001–003 (k3s itself, GitOps via
ArgoCD, Longhorn PVC over hostPath for the Nextcloud migration) predate
the ADR habit and were never written up. Their reasoning is partly
captured in architecture.md; the numbers stay reserved rather than
reused.
