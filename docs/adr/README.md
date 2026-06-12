# Architecture Decision Records

Short documents capturing *why* a decision was made — what was considered, what was rejected, and why the chosen approach won. Written after the fact, kept as permanent record.

Each ADR has a **Status** (Accepted / Superseded) and a **Superseded By** line so reversed decisions show their evolution rather than being silently rewritten.

| File | Decision |
|---|---|
| 004-restic-b2-bckup.md | Offsite backup with restic to Backblaze B2 |
| 005-victoria-metrics-monitoring.md | VictoriaMetrics single-node over kube-prometheus-stack |
| 006-immich.md | Immich: public before Authelia, raw manifests, 100MB tunnel cap accepted, backed up from day one |

Numbering starts at 004: decisions 001–003 (k3s itself, GitOps via
ArgoCD, Longhorn PVC over hostPath for the Nextcloud migration) predate
the ADR habit and were never written up. Their reasoning is partly
captured in architecture.md; the numbers stay reserved rather than
reused.
