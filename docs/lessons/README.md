# Lessons (Incident Log)

Post-mortems filed after anything that caused downtime, data risk, or significant wasted time. Organised by domain:

- `infra/`, Proxmox host, hardware, networking below k3s
- `k8s/`, cluster-level issues (pods, controllers, storage)
- `networking/`, DNS, Traefik, cloudflared, tunnels
- `storage/`, Longhorn, ZFS, PVC issues
- `backup/`, restic, B2, restore failures

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
| networking/certmanager-dns01-split-horizon.md | networking | First wildcard issuance stuck twice: Technitium answers the local zone's NS as `technitium.` (poisons the DNS-01 self-check), then the Vodafone hub turned out to drop *all* outbound port 53 — self-check moved to DoH. Also exposed Collabora's silently broken DNS hairpin |
| k8s/act-runner-dind-mtu-oom.md | k8s | Gitea Actions bring-up: DinD bridge MTU 1500 vs pod 1450 black-holed job internet TLS (`curl (35)` reset after ~2.5min; checkout worked); plus act_runner Go-GC OOMKilled at 192 & 384Mi until `GOMEMLIMIT` + 768Mi |
| k8s/act-runner-no-docker-daemon.md | k8s | act_runner job steps can't `docker build` — the dind sidecar gives the *runner* a daemon, not the job container (no `docker.sock`, `DOCKER_HOST` not propagated). Portfolio's image build moved to GitHub-hosted runners |
| networking/proxmox-401-secure-cookie-plain-http.md | networking | Proxmox login 401'd through Traefik (and public 404'd): PVE's auth cookie is `Secure`, so a plain-HTTP browser drops it → 401 right after login; route was web-only so HSTS/split-horizon hit websecure → 404. Fixed with a second `websecure` IngressRoute (a `tls` block is required to serve websecure but makes the router TLS-only, so it must be two routes) |
| k8s/worker-reboot-alert-storm.md | k8s | A worker reboot fired ~20 `PodCrashLooping` alerts ~20 min late, all for already-healthy pods (Longhorn reattach crashloops + the alerter on the same worker, batch-flushed on recovery; triage by the *absence* of `PodOOMKilled`). Delayed second act: the reboot's salvage/rebuild work bloated the control-node `longhorn-manager` ~150MiB hours later, tripping `NodeMemoryLowControl` — fixed by bouncing the manager |
| k8s/nextcloud-cron-multiattach-rwo.md | k8s | `nextcloud-cron` failed ~half its runs with `KubeJobFailed` — RWO `nextcloud-data` attaches to the main pod's node, but the CronJob had no affinity so off-node runs hit `FailedAttachVolume` → `DeadlineExceeded`. HOMELAB.md already documented "podAffinity pins to worker"; the manifest had drifted. Fixed with podAffinity on `app: nextcloud`. Audited the backup CronJobs (nextcloud/gitea/immich) — all already carry the affinity; the 5-min cron was the lone job that missed the pattern |
