# Lessons (Incident Log)

Post-mortems filed after anything that caused downtime, data risk, or significant wasted time. Organised by domain:

- `infra/` — Proxmox host, hardware, networking below k3s
- `k8s/` — cluster-level issues (pods, controllers, storage)
- `networking/` — DNS, Traefik, cloudflared, tunnels
- `storage/` — Longhorn, ZFS, PVC issues
- `backup/` — restic, B2, restore failures

Use `TEMPLATE.md` for new entries. Each entry covers: date · context · symptoms · investigation (including dead ends) · root cause · fix · verification · prevention.

## Current entries

| File | Domain | Summary |
|---|---|---|
| infra/e1000e-nic-hang.md | infra | Intel onboard NIC TX ring stall — host unreachable, required hard reboot |
| infra/nextcloud-lxc-firewall-port11000.md | infra | Proxmox LXC firewall silently blocked port 11000 (AIO frontend) |
| infra/wireguard-lxc-dstate-freeze.md | infra | `pct enter` into WireGuard LXC while VPN active → D-state freeze, host reboot required |
| k8s/grafana-pvc-corruption.md | k8s | Reused Grafana PVC with corrupt SQLite across reinstalls → CrashLoopBackOff |
| k8s/grafana-monitoring-sync-cascade.md | k8s | Six-bug cascade: orphaned ArgoCD app → kiwix syncOptions → PrometheusRule vs VMRule → plugin 404 → datasource isDefault collision → Grafana OOMKill |
| k8s/k3s-control-plane-false-positives.md | k8s | ~12 false-positive alert emails/night — chart's control-plane rules (scheduler/CM/etcd/proxy Down) assume kubeadm; k3s runs them in-process. Verified alive before silencing |
| k8s/argocd-comparisonerror-silent-values.md | k8s | Bad inline Helm values (indent / duplicate key / typo'd key) → silent ArgoCD ComparisonError or last-wins; live workloads keep running old spec, no surface symptom |
| k8s/alertmanager-null-route-typo.md | k8s | `reciever` typo → drop route inherits `email`, so Watchdog leaked to inbox; drop route ordered after critical; `InforInhibitor` matcher matched nothing. Silent — config loaded fine |
| k8s/collabora-slow-load-wordbook.md | k8s | Collabora cold opens ~55 s — hunspell en_GB.dic uploaded as personal wordbook; DictionaryNeo quadratic load per kit. Two-day detour fixing a coincident jail-copy/AppArmor pathology first (raw logs alongside) |
| networking/proxmox-502-selfsigned-tunnel.md | networking | Cloudflare tunnel returned 502 for Proxmox — self-signed cert on :8006 |
| networking/vodafone-hub-ghost-portforward.md | networking | Vodafone Hub silently wiped port-forward rules after DHCP change |
| k8s/argocd-selfheal-backup-race.md | k8s | selfHeal reverted the Gitea backup's scale-to-0 within seconds — every "consistent" SQLite backup actually ran against a live Gitea. Fixed with ignoreDifferences on replicas |
| storage/zfs-snapshot-retention-noop.md | storage | Nightly ZFS prune failed silently since setup (`zfs destroy` multi-arg) — and its selection logic would have deleted the wrong snapshots if it had worked |
