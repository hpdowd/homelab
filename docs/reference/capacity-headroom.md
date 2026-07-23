# Capacity & RAM headroom

The gating factor for "should I add service X" is RAM on the worker node.
This is the report that answers it for the current state, plus how to
re-run it. Pairs with the Grafana "Homelab, Capacity & RAM headroom"
dashboard (`k8s/apps/monitoring/grafana-dashboard-capacity.yaml`).

> **Status update 2026-07-23 (paperless):** phase 10 (paperless-ngx v3.0.0,
> ADR 015) authored for the worker — three pods (app + Postgres 18 + Valkey).
> Live worker figures at authoring time (superseding the pre-shrink snapshot
> table below): MemAvailable **3.87GiB idle**, **7d min 2.66GiB**, 7d max
> genuine used **8.96GiB** — i.e. the worker already touched ~0.66GiB above
> the 2GiB `NodeMemoryLowWorker` floor, almost certainly an Immich ML import
> burst. Paperless adds ~0.8–1.1GiB steady, ~1.5–1.8GiB during an OCR burst
> (limit capped 1.5Gi, `TASK_WORKERS=1`). Steady state fits (~2.8GiB free
> after); the one risk is a big-scan OCR burst **concurrent with** an Immich
> ML import breaching the 2GiB floor. Both bursts are user-triggered — stagger
> the initial bulk ingest, and record resident RAM idle-vs-mid-ingest here
> once measured.
>
> **Status update 2026-07-23:** homepage (phase 9, the household dashboard)
> deployed to the worker. Negligible against the budget — one stateless
> Next.js container, `requests 64Mi`, `limits 256Mi`, ~40–80Mi resident, no
> PVC. Doesn't move any of the figures below; noted for completeness.

> **Status update 2026-06-28:** control VM raised **4→5GiB** (now 4.74GiB
> usable; `MemAvailable` recovered ~0.7→~2.9GiB). This was *not* fallout
> from the worker shrink: the 2026-06-27 worker reboot's Longhorn
> salvage/rebuild bloated the control-node `longhorn-manager` ~150MiB for
> hours, which on the thin 4GiB control node tripped `NodeMemoryLowControl`
> after the crashloop storm had cleared
> (`docs/lessons/k8s/worker-reboot-alert-storm.md`). 1GiB over 512MiB
> because 512 covers that spike but not the multi-day apiserver/kine drift.
> Net of both VM changes the host keeps ~1GiB of the worker shrink's 2GiB,
> so the software-only game-server budget is **~3.5-4GiB** (worker 12GiB +
> control 5GiB = 17GB fixed of ~24).

> **Status update 2026-06-27:** worker VM shrunk **14→12GiB** (now
> 11.6GiB usable, `node.status.capacity.memory` = 12184516Ki) to hand
> ~2GiB back to the host for an AMP game server. The worker is the only
> RAM lever left: ZFS ARC is already capped at 2.3GiB (10%, sitting at
> ~1.2), and control stays at 4GiB (its 3.5GiB shrink was cancelled,
> see below). Live at shrink time: worker 7.0GiB working set (59%), no
> OOM or `MemoryPressure` through a graceful `qm shutdown`/`start`; host
> `free -h` available rose ~4.3→~6GiB. The cycle did trigger a transient
> Longhorn-reattach crashloop **alert storm** (benign, self-resolved):
> `docs/lessons/k8s/worker-reboot-alert-storm.md`. Software-only
> game-server budget is now **~4-5GiB** (small servers, Valheim, PZ,
> Nomifactory at 3-4GiB heap); moderate modpacks and SkyFactory wait for
> a separate box. **The "13.59GiB usable" figures below predate this
> shrink** and read against the old 14GiB worker.

> **Status update 2026-06-12:** both candidates below are deployed,
> Collabora (phase 6d) and Immich (phase 6c, ADR 006). Immich went in on
> a ~6-day baseline showing a 7.9GiB worker minimum; post-deploy idle is
> ~6.8GiB available. The feasibility numbers below are kept as the
> record of the decision. Still owed: watch `MemAvailable` through the
> first big library import, and re-pull the distribution afterwards.

## The reframing that actually matters

The host's tight ~6GB free is **not** the constraint for in-cluster
workloads. The worker VM (301) reserves its full 14GiB from the host the
moment it boots, idle or not; that RAM is already spent from the host's
point of view. Most of it sits unused inside the VM. So filling it costs
the host nothing; the only question is whether a new workload fits inside
the worker VM's 13.59GiB usable (`MemTotal`, the 14GiB reservation minus
kernel-reserved).

This flips the usual instinct: adding services that live *inside* the
worker is "free" against the host budget. Adding another LXC/VM is not.

## Snapshot: 2026-06-10

Verifying the claim "worker1 generally sits under 50% of its 14GiB and
almost never exceeds it." Pulled from VictoriaMetrics.

**⚠️ Data window caveat:** the VM TSDB only held ~4.2 days at the time of
this report; it was reset when the monitoring stack was redeployed
(`vm-operator` svc age ~4d). So this verifies the *current steady state*
with all present workloads, **not** a long baseline. See "Re-evaluate"
below; this is exactly why the note exists.

Worker1 genuine used memory (`MemTotal − MemAvailable`, excludes
reclaimable cache), 1214 samples @5min over ~4.2 days:

| | used % | used GiB |
|---|---|---|
| min | 22.0% | 2.99 |
| median | 34.5% | 4.68 |
| avg | 34.7% | 4.71 |
| p95 | 37.4% | 5.09 |
| **max** | **38.6%** | **5.24** |
| **time spent > 50%** | **0.0%** | — |

- `MemAvailable` never dropped below **8.35GiB** (the `NodeMemoryLowWorker`
  alert fires at <2GiB).
- Swap effectively zero (≤1Mi).
- `kubectl top node` showed 44% / 6.1GiB at the same moment; that's the
  cadvisor working-set figure, which counts more than node-exporter's
  "genuine used". Both agree: comfortably under 50%.

**Verdict:** claim holds, and conservatively. Peaked at ~39%, zero time
above 50%.

Other headroom at snapshot time:

- Pod memory **requests** total only 2.6GiB on worker (most pods declare
  none), **limits** total 8.91GiB. Genuine working set ~4.7GiB.
- CPU: 2.15 / 8 cores requested, ~3% utilisation. Not a constraint.
- Longhorn vdb: **69 / 491GiB used (14%)**, ~422GiB free.
- OS root (worker): 17 / 28.8GiB (59%).

**Workable budget for new in-cluster workloads:** to stay above the 2GiB
`NodeMemoryLowWorker` alert floor, ~6.5–6.9GiB before it trips
(~11.6GiB before genuine exhaustion).

## Feasibility read (Collabora / Immich)

Figures below are **estimates from each project's resource profile, not
measured on this box.** The real test is deploying with limits and
watching, especially the first bulk import.

| Workload | Est. footprint | Read |
|---|---|---|
| **Collabora (CODE)** — re-enable `richdocuments` against self-hosted CODE | ~1GiB base + ~0.5GiB/active doc → **1.5–2GiB** for 1–2 users | **Green.** Fits with ~5GiB to spare. CPU-spiky on doc conversion, but 6 idle cores. |
| **Immich** | ML container 1.5–2.5GiB (the hog) + server ~0.4 + pg/pgvector ~0.3–0.5 + redis ~50Mi → **2.5–3.5GiB steady, 4–5GiB during ML import** | **Amber, feasible alone.** It's the gating workload. Deploy with explicit limits (esp. `immich-machine-learning`), watch the first library import — that's the worst-case spike, not steady state. |
| **Both at once** | ~4.5–5.5GiB steady | Possible, thin margin. A simultaneous Immich ML import burst could push `MemAvailable` toward the 2GiB alert. **Stage them, don't co-deploy.** |

Recommendation: Collabora first (low risk), Immich second with limits +
dashboard watch through the initial import, reassess "both long-term"
once Immich's real import peak is known.

## How to re-run this report

The numbers above came from querying `vmsingle` directly. Port-forward it:

```bash
kubectl port-forward -n monitoring svc/vmsingle-vm-victoria-metrics-k8s-stack 8428:8428
```

Then hit the Prometheus-compatible API (worker1 = `192.168.1.11:9100`):

```bash
# Usable total
curl -s 'http://localhost:8428/api/v1/query?query=node_memory_MemTotal_bytes{instance="192.168.1.11:9100"}'

# How much history is actually retained (check the window before trusting stats)
curl -s 'http://localhost:8428/api/v1/query?query=node_memory_MemTotal_bytes{instance="192.168.1.11:9100"}[40d]'

# Genuine used over a range — feed to query_range, step 300s, and take
# min/median/avg/p95/max + fraction of samples over your threshold:
#   node_memory_MemTotal_bytes - node_memory_MemAvailable_bytes
# Alert-relevant floor:
#   node_memory_MemAvailable_bytes   (NodeMemoryLowWorker fires < 2GiB)
```

Quick instantaneous gut-check without VM:

```bash
kubectl top node
kubectl top pods -A --sort-by=memory | head -20
```

## Re-evaluate

This report is a 4-day snapshot. **Re-run it when:**

- the worker has a meaningfully longer baseline (≥2–3 weeks of TSDB) so
  peaks aren't hidden by the short window, the 2026-06-10 figures came
  from only ~4.2 days because the TSDB had just been reset;
- **after each new service is added** (Collabora, then Immich), re-pull
  the distribution and, for Immich specifically, watch `MemAvailable`
  through the first full library import, which is the real worst case;
- before deciding whether *both* Collabora and Immich can coexist
  long-term.

To stop the next monitoring redeploy from wiping the baseline again,
consider bumping the VM TSDB retention / PVC so a longer window survives.
