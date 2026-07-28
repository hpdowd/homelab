# ADR 013: file-parser switches to the pdfium PDF engine

**Status:** Accepted
**Date:** 2026-07-20

## What problem this solves

`docs/lessons/k8s/file-parser-oom-large-pdf.md` covers the incident: a 200+
page PDF OOMKilled the (single-replica) file-parser pod because the parser
built the whole document in memory before returning anything. The immediate
fix for that was app-level — stream the PDF page-by-page instead of
materializing it — and it worked: peak parse memory dropped from unbounded
(OOMing a 1Gi pod) to ~112Mi even on 200+ page reports, so `limits.memory`
went back down from the 3Gi mitigation to 1Gi.

That fixed the memory blowup. It didn't touch the other side of the same
input: a 200+ page PDF is also just *slow* to parse page-by-page in pure
Python (`pdfplumber`). Streaming solved the crash; it didn't make a long
report pleasant to wait on.

## What I picked

**pdfium (`pypdfium2`) as the extraction engine, `pdfplumber` kept as the
fallback.** pdfium wraps Google's PDFium C library instead of parsing in
pure Python, so it's ~3.6–4x faster at effectively the same memory profile
the streaming rewrite already established — the speed comes from a faster
engine, not from spending more RAM.

Rolled out in three steps rather than one, each independently revertible:

1. `sha-7236520` — image gains the pdfium backend, `PARSER_ENGINE=pdfium` set
   explicitly in the ConfigMap. Engine selectable at runtime, running live to
   validate before committing to it as the default.
2. `sha-ef055b2` — pdfium promoted to the image's own default. The explicit
   ConfigMap override becomes redundant and is dropped; `PARSER_ENGINE` is
   now only needed to force the `pdfplumber` fallback.

`PARSER_ENGINE` stays a real switch, not removed — an escape hatch if pdfium
ever mis-renders something pdfplumber handled correctly.

## What I rejected

- **Stop at the streaming fix.** Solves the crash but leaves parse latency
  scaling with page count on the slow path. Given the whole incident started
  with someone waiting on a long report, latency was worth fixing too, not
  just the OOM.
- **Optimize the pure-Python parse further** (e.g. more aggressive
  streaming, caching, tuning `pdfplumber` itself). Possible, but pdfium
  swaps in a C library built for exactly this instead of hand-tuning
  Python — better return for the effort, and it's a drop-in backend rather
  than a rewrite of the streaming logic just landed.
- **Ship pdfium straight to default without the intermediate explicit-flag
  step.** The flag step cost one extra deploy and bought a live check with a
  real fallback available the whole time, rather than betting the only
  extraction path on a new engine in one move.

## Consequences

- **file-parser is faster on every parse, not just large ones** — the
  reported ~3.6–4x is at roughly the same memory as the post-streaming
  baseline, so this isn't a speed-for-memory trade.
- **Two PDF backends now live in the image** (`pdfium` default,
  `pdfplumber` fallback) — marginally more surface than one engine, accepted
  because it's what makes `PARSER_ENGINE=pdfplumber` a real rollback instead
  of a revert-and-redeploy.
- **The 1Gi / 512Mi limits from the streaming fix stand unchanged** — pdfium
  didn't move the memory ceiling, only the wall-clock time to hit a result.
- **Prevention item from the incident lessons doc still applies**: profiling
  against a deliberately long PDF, not just a large one, remains the reflex
  before shipping changes to this path — pdfium changed the engine, not the
  need for that check.

## Related

- docs/lessons/k8s/file-parser-oom-large-pdf.md — the OOM incident that
  started this: mitigation (memory bump) then real fix (streaming rewrite)
- Manifests: k8s/apps/file-parser/deployment.yaml, configmap.yaml
