# Incident: kiwix OOMKilled — libzim cluster cache is bounded per ZIM, not by bytes

## Date
2026-08-15

## Time lost
~1h to alert triage and root cause. Fix staged, not yet applied (see Status).

## Status
Resolved

Root cause confirmed, fix synced via ArgoCD (`5d966ab`) and load-tested
against the running pod — anon memory plateaus at ~202MiB under load heavier
than real traffic, against a 768Mi limit. Worth noting the alert had already
"self-resolved" on its own before any of this: the pod restarted and came back
Ready, which is precisely what made it look like a non-event.

## Context
- **System / component:** `kiwix` Deployment, `kiwix` namespace, single
  replica on `k3s-worker1`. `ghcr.io/kiwix/kiwix-serve:3.7.0`, 512Mi limit.
- **Scope:** kiwix only. `wiki.lan` + `wiki.henrydowd.dev`, no other service
  affected. Offline-wiki reader, so effectively zero user impact.
- **State before:** idle. The pod had been recreated on 2026-08-10 23:49 as
  part of the containerd/local-path move to `vdb`, and was serving ~0 req/s.

## Symptoms
- `PodOOMKilled` (critical, → email) firing for `kiwix/kiwix-6596d485bf-x8szf`.
- `kubectl describe`:
  ```text
  Last State:     Terminated
    Reason:       OOMKilled
    Exit Code:    137
  ```
- One-off at first glance — `RESTARTS 1`, pod Running and Ready again by the
  time the alert was looked at. That is the misleading part; see below.

## Investigation
- **Hypothesis 1: the node was starved.** Ruled out. `node_memory_MemAvailable_bytes`
  on `k3s-worker1` sat between 3.79 and 4.13 GiB for the whole 24h window,
  with no dip anywhere near the kill. The alert's own description offers
  "limit too low **or** node starved" — it was not the node.
- **Hypothesis 2: the 512Mi limit was always marginal.** Ruled out, and this
  is the one worth recording. The 30-day working-set series shows kiwix at a
  flat **17–27 MiB for a solid month**, then:
  ```text
  07-16 → 08-10   18–27 MiB   (flat, a month)
  08-11 19:00     20 → 57     inflection
  08-12           154 → 306
  08-13           377 → 432
  08-14 → 08-15   ~452        plateau at the ceiling → OOMKill
  ```
  A limit that held 25x headroom for a month is not "always marginal";
  something changed in behaviour.
- **Hypothesis 3: mmap'd ZIM page cache.** Ruled out, and this was the useful
  dead end — it is the intuitive answer for a process serving 3.8G of ZIMs.
  Splitting the cgroup counters kills it:
  ```text
  container_memory_rss           17 → 154 → 306 → 406 → 452 MiB   (climbs, never returns)
  container_memory_cache          3 → 260 → squeezed back to 50   (reclaimed)
  container_memory_mapped_file   ~6 MiB throughout                (never a factor)
  ```
  `mapped_file` staying at ~6 MiB says the ZIMs are **not** being held mapped.
  The growth is **anonymous heap**, and `cache` being squeezed 260 → 50 while
  RSS climbs is the cgroup reclaiming file pages to make room for that heap —
  the classic pre-OOM signature.
- **Hypothesis 4: per-request leak, driven by traffic.** Confirmed. Traefik
  request rate to the kiwix service was ~0.00 req/s for the entire month, then
  sustained 1–3 req/s from 08-12 onward, steady across all hours including
  00h–06h (bot-shaped, not human). RSS ratchets up with each burst of requests
  and stays flat between them — it never recovers. Cumulative requests, not
  concurrent load, is the variable.

The confirming detail: the "recovered" pod was measured 18 minutes after its
restart and was already at `anon` 172 MiB / `memory.current` 488 MiB against
the 536,870,912-byte limit — 91% of the way back to another OOM. This was
never a one-off, it is a loop with a ~24h period that happens to self-heal.

## Root cause
libzim caches **decompressed** ZIM clusters, and the cache is bounded by
cluster **count per ZIM** (`ZIM_CLUSTERCACHE`, default 16), not by total
bytes. This PVC holds **12 ZIMs**, so the steady-state ceiling is
`12 x 16 x <cluster size>`, which at ~2 MiB/cluster is ~380 MiB of anon
memory plus the rest of the process — landing on the observed ~452 MiB
plateau, just over a 512Mi limit.

Nothing about the deployment changed on 08-11. What changed is that a crawler
started walking the public `wiki.henrydowd.dev`, and touching more of the
library monotonically fills a cache that has no byte bound and no TTL. The
config had been latently wrong since the ZIM count grew; a month of ~0 req/s
simply never filled the cache far enough to expose it.

This is known upstream, not a local misconfiguration:
kiwix/libkiwix#1025 (no purge of cached ZIMs/entries) and kiwix/operations#147
(cache defaults too large, needs customising).

## Fix
Bound the cache rather than chase it with the limit — `k8s/apps/kiwix/deployment.yaml`:

```yaml
env:
  - name: ZIM_CLUSTERCACHE
    value: "4"
resources:
  requests: { memory: "128Mi", cpu: "50m" }
  limits: { memory: "768Mi" }   # was 512Mi
```

`4 x 12 ZIMs` ≈ 100 MiB of cluster cache. The 768Mi is margin, not the fix —
raising the limit alone would only have moved the OOM a day or two out, since
the cache grows to whatever ceiling it is given. Measured plateau came in at
~202 MiB anon, so 768Mi leaves ~3.8x headroom.

Left alone on purpose: `KIWIX_ARCHIVE_CACHE_SIZE` / `KIWIX_SEARCHER_CACHE_SIZE`
default to ~10% of book count, which is negligible at 12 books. Search turned
out to be the larger half of the footprint, but it bounds itself at ~202 MiB,
so there was nothing to buy by tuning them.

Applied via ArgoCD auto-sync on push (`5d966ab`).

## Verification
Done so far — that the var name is real for *this* build, rather than trusting
docs written against a newer version. 3.7.0 is statically linked, so the
env names are greppable straight out of the binary:

```bash
kubectl exec -n kiwix deploy/kiwix -c kiwix -- \
  grep -ao "ZIM_CLUSTERCACHE\|ZIM_DIRENTCACHE\|KIWIX_ARCHIVE_CACHE_SIZE" \
  /usr/local/bin/kiwix-serve | sort -u
# → ZIM_CLUSTERCACHE, KIWIX_ARCHIVE_CACHE_SIZE, KIWIX_SEARCHER_CACHE_SIZE,
#   ZIM_DIRENTLOOKUPCACHE
```

Worth noting: `ZIM_DIRENTCACHE` is documented upstream but is **absent** from
this binary. Setting it would have been a silent no-op — which is the general
hazard with tuning by env var, since an unrecognised name never errors.

Then synced and load-tested against the running pod, rather than waiting days
on the crawler. Load was driven at the Service from an in-cluster pod, all
responses checked for HTTP 200 (the first attempt at this silently 404'd —
`/random?content=` wants the *content id* with the date suffix,
`serverfault.com_en_all_2026-02`, not the catalog `<name>`. 300 requests of
"flat memory" that were all 404s proved nothing. Always assert the status
code before believing a load test).

**Article reads — cluster cache bound holds:**

| after | requests | anon |
|---|---|---|
| T0 | 0 | 26 MiB |
| T1 | 600 | 60 MiB |
| T2 | 1200 | 59 MiB |
| T3 | 1800 | 59 MiB |

Fills once, then completely flat over 1200 further reads — against the
pre-fix behaviour of an unbroken 17 → 452 MiB climb.

**Search — a separate path, also bounded.** Article reads alone were not a
sufficient test; xapian searchers allocate independently of the cluster cache:

| after | searches | anon |
|---|---|---|
| S1 | 120 | 199 MiB |
| S2 | 240 (new terms) | 202 MiB |
| S3 | 360 (repeat terms) | 202 MiB |

Search is the bigger half of the footprint and most of it arrives on the
first few queries, but it plateaus at ~202 MiB and holds.

**Reading the result correctly.** At S2/S3 `memory.current` was 764MiB of the
768Mi limit — 99%, which looks like the original problem. It is not:

```text
anon=202MiB  file=559MiB  inactive_file=404MiB  current=764MiB
memory.events: low 0  high 0  max 750  oom 0  oom_kill 0
```

`max 750` means the cgroup kept hitting its ceiling and **reclaiming**, with
`oom_kill 0` throughout. That is page cache correctly expanding to fill the
cgroup and being evicted at the boundary. The pre-fix signature was the exact
inverse — anon climbing while `cache` was squeezed 260 → 50MiB to make room.

So: judge this on **`container_memory_rss` / cgroup `anon`**, never on
`working_set` or `memory.current`, both of which will sit near the limit by
design and mean nothing on their own. Over ambient traffic, judge on the
multi-day trend — a fresh pod reads low for its first hour regardless of
whether the fix works, which is exactly what made the original OOM look like
a one-off.

## Prevention
- The alert did its job; triage did not. `PodOOMKilled` on a pod that is
  Running/Ready again reads as self-resolved, and the natural move is to note
  it and move on. **A single OOMKill with a healthy pod behind it still needs
  the multi-day memory trend pulled** — the trend is what separates a one-off
  from a 24h sawtooth. Same lesson as the flat `RESTARTS 1`.
- Splitting `rss` / `cache` / `mapped_file` rather than reading
  `working_set_bytes` alone is what turned "the limit is too low" into a
  root cause. Working set conflates reclaimable cache with a real heap.
- Open question, deliberately not actioned here: `wiki.henrydowd.dev` is
  public and ungated, and every request it serves is currently a bot. Whether
  that endpoint should be public at all, rate-limited at Traefik, or given a
  `robots.txt`, is a separate decision — but note that the crawl is what
  turned a latent misconfiguration into a recurring outage.
- Worth revisiting: 3.7.0 is pinned from 2024-03-13 and upstream is now 3.8.2.
  Nothing in the 3.8.x notes claims a cache fix, so this is hygiene, not a
  fix for this incident.

## Related
- Other lessons: `docs/lessons/k8s/file-parser-oom-large-pdf.md` (same shape —
  a limit sized for the ordinary case meeting an unbounded footprint; there
  the bound was page count, here it is ZIM count x cache depth),
  `docs/lessons/k8s/worker-reboot-alert-storm.md` (triaging by what the alert
  set does *not* contain)
- Upstream: https://github.com/kiwix/libkiwix/issues/1025 ·
  https://github.com/kiwix/operations/issues/147
