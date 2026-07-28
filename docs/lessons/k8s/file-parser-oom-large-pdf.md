# Incident: file-parser OOMKilled on a 200+ page PDF

## Date
2026-07-20

## Time lost
~2h from first 502 to service restored at the new limit; root-caused and
properly fixed the same day.

## Status
Resolved

## Context
- **System / component:** `file-parser` Deployment, `file-parser` namespace,
  single replica pinned to `k3s-worker1`.
- **Scope:** file-parser only, but user-facing and single-replica — the OOM
  took the whole service down, not just one request.
- **State before:** parsing a normal upload — a report PDF, just an unusually
  long one (200+ pages).

## Symptoms
- Upload returned a 502/503 from Traefik. Reloading the page from the LAN
  gave "couldn't connect to server".
- A minute or two later, alertmanager emailed that the pod had crashed —
  OOMKilled.
- One-off: smaller PDFs had never triggered this. Page count, not file size,
  was the variable that mattered.

## Investigation
- `limits.memory` was 1Gi at the time — set when the app was first deployed,
  sized for the ordinary case (a few-page invoice/report), never revisited.
- Immediate call: restore service first, root-cause after. Raised
  `limits.memory` 1Gi→3Gi and the memory-backed `/tmp` `sizeLimit` 512Mi→2Gi
  (commit `67d5950`) purely to get uploads working again while the real
  cause was dug into.
- Root cause turned out to be app-level, not a k8s sizing problem: the parser
  built every page of the PDF in memory before returning anything, so memory
  scaled with page count instead of being bounded. A 200+ page report was
  enough to blow past 1Gi even though the same code had handled every
  smaller PDF fine for months.

## Root cause
The parser materialized the whole document in memory during parse instead of
processing it incrementally. Memory footprint scaled linearly with page
count with no cap, so the limit that comfortably covered typical uploads had
no margin against a long tail one.

## Fix
Two stages, same day:

1. **Mitigation** — raise the ceiling so the mode of failure (any large PDF
   OOMs the single pod) stopped being live while a real fix was built.
   `limits.memory` 1Gi→3Gi, tmp `sizeLimit` 512Mi→2Gi. Commit `67d5950`.
2. **Actual fix** — rewrote the parser to stream page-by-page instead of
   building the whole document in memory (image `sha-36e448d`). Peak parse
   memory dropped to ~112Mi even on 200+ page reports; LibreOffice render
   peaks ~175Mi; worst case under `MAX_CONCURRENCY=2` is ~350Mi + tmpfs.
   `limits.memory` dropped back 3Gi→1Gi, tmp back 2Gi→512Mi to match the new,
   bounded footprint. Commit `1c66594`.

The mitigation was deliberately temporary — 3Gi was never the right number,
it was a number that bought time.

## Verification
```
kubectl -n file-parser get pods
# file-parser-856c495799-82ngp   1/1   Running   0   12h
```
Zero restarts and 12h+ uptime as of writing, spanning the memory fix and the
subsequent pdfium engine rollout (see ADR 013) — no repeat OOMs.

## Prevention
- Single replica means any crash is a full outage, not degraded capacity —
  accepted for now given file-parser's traffic, but worth remembering if it
  starts seeing heavier or more concurrent use.
- `MAX_UPLOAD_MB` bounds file size, not page count or parse cost — those
  aren't the same axis, and this incident is the reason to remember that.
- Memory profiling against a deliberately pathological input (a long PDF, not
  just a large one) is now the reflex before shipping parse-heavy paths here,
  the same way `GOMEMLIMIT` became the reflex for Go workloads after
  `k8s/act-runner-dind-mtu-oom.md`.

## Related
- ADR: docs/adr/013-file-parser-pdfium-engine.md
- Manifests: k8s/apps/file-parser/deployment.yaml, configmap.yaml
