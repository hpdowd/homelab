# Incident: Collabora cold document opens took ~55 s (oversized personal wordbook)

## Date
2026-06-09 → 2026-06-11 (symptom present for weeks before being investigated)

## Time lost
~2 days of active debugging — most of it spent confirming and fixing a *second,
coincident* pathology (jail-copy fallback) that turned out not to be the cause.

## Status
Resolved

## Context
- **System / component:** namespace `collabora`, CODE pod pinned to `k3s-worker1`;
  Nextcloud `richdocuments` (WOPI host) in namespace `nextcloud`.
- **Scope:** every *cold* document open in Nextcloud Office (docx/xlsx/pptx).
- **State before:** fresh Collabora deployment (phase 6d); worker VM still on the
  generic `x86-64-v2-AES` vCPU model (since changed to `cpu: host`).

## Symptoms
- Cold open: editor frame at ~7 s, document **editable only at ~55 s**.
- A document already open in another session opened instantly.
- Near-identical ~55 s for docx and xlsx, across two CODE major versions →
  fixed per-kit cost, not proportional to document content.
- During the slow window: one process (the document's kit) pegged exactly one
  core, pure userspace compute, flat memory, zero I/O wait.
- `serverloadtimings` put the gap at `loadDocumentEnd → firstTileSent ≈ 48 s`,
  with a suspiciously fat `presetsInstall ≈ 3.4 s`.
- `perf` on the burning kit:
  ```text
  26%  libmergedlo.so  DictionaryNeo::cmpDicEntry(u16string_view, u16string_view, bool)
  21%  libuno_sal.so.3 rtl_uString_acquire
  21%  libuno_sal.so.3 rtl::str::release<_rtl_uString>
  11%  libmergedlo.so  DictionaryNeo::isSorted()
  ```
  `DictionaryNeo` = LibreOffice's **wordbook** (user dictionary) loader.

## Investigation
Full evidence-tagged logs (FACT/INFERENCE/CORRECTION method): see
[collabora-slow-load-investigation-v2.md](collabora-slow-load-investigation-v2.md)
and [collabora-slow-load-investigation-v3.md](collabora-slow-load-investigation-v3.md).
Condensed hypothesis trail, including the dead ends:

- Readiness-probe flapping → ruled out: 0 restarts, stable curls.
- Cloudflare/WOPI reachback latency → ruled out: file fetch ~207 ms vs 48 s gap.
- Memory pressure/OOM → ruled out: flat RSS, idle node.
- CODE 26.04 regression → ruled out: downgrade to 25.04 changed nothing.
- fontconfig rebuild per jail → ruled out by perf (no FreeType/fontconfig symbols).
- **Jail-copy fallback** (the big detour): CODE *was* copying the whole LO tree
  into every jail because the default `cri-containerd.apparmor.d` profile denies
  `mount(2)`, and the deprecated AppArmor *annotation* never applied on k3s 1.35.
  Switching to the `securityContext.appArmorProfile: {type: Unconfined}` **field**
  (plus the capability list feeding CODE's file-caps helpers) got bind-mounted
  jails: setup 48 s of copying → **6 ms**. Real fix, worth keeping —
  **but the symptom was unchanged**, proving the copy was coincident, not causal.
- Misreading along the way: pid 1 `CapEff=0` was taken as "caps not applied";
  it is the *healthy* state — CODE uses file capabilities on `coolmount` /
  `coolforkit-caps`, which only need the caps in the *bounding set*.
- perf profile finally pointed at `DictionaryNeo` → wordbook presets → found it.

## Root cause
A full **hunspell `en_GB.dic` (587,750 bytes, 51,573 affix-flagged entries)** had
been uploaded as the *personal wordbook* for user `henry` in Nextcloud Office
settings (2026-04-01), stored at
`appdata_*/richdocuments/userconfig/henry/wordbook/English (British).dic`.

On every cold open, CODE's presets mechanism downloaded it into the kit jail
(`presetsInstall` ~3.4 s), then `DictionaryNeo` parsed and **sort-inserted all
51,573 entries on first spellcheck** — between `loadDocumentEnd` and
`firstTileSent` — which is comparison-quadratic (~10⁹ `cmpDicEntry` calls plus
`rtl_uString` refcount churn) ≈ 48 s on the then-crippled vCPU. Warm sessions
were instant because the assigned kit had already paid the cost.

The file was also *useless*: en_GB spellcheck already comes from the proper
hunspell dictionary (`dictionaries: en_GB en_US`), and hunspell entries with
affix flags (`émigré/S`) never match anything as literal wordbook words.

## Fix
```bash
# backup (kept at ~/backup-English-British.dic.bak)
kubectl exec -n nextcloud deploy/nextcloud -- \
  cat "/var/www/html/data/appdata_*/richdocuments/userconfig/henry/wordbook/English (British).dic" \
  > ~/backup-English-British.dic.bak
# remove the wordbook (the real one, standard.dic, untouched)
kubectl exec -n nextcloud deploy/nextcloud -- \
  rm "/var/www/html/data/appdata_*/richdocuments/userconfig/henry/wordbook/English (British).dic"
# resync Nextcloud's file cache
kubectl exec -n nextcloud deploy/nextcloud -- \
  su -s /bin/sh www-data -c 'php occ files:scan-app-data richdocuments'
# flush kit/preset state
kubectl rollout restart deploy/collabora -n collabora
```
Declarative remnant cleanup in `k8s/apps/collabora/deployment.yaml` (same
commit as this file): image restored to 26.04 (the downgrade was a ruled-out
test), debug logging removed, prespawn spare added, load-bearing
AppArmor/capability settings commented so they don't look like cruft.

## Verification
- Wordbook dir now contains only `standard.dic` (300 B, 35 genuine entries).
- Cold open after fix: editable in seconds — confirmed by user 2026-06-11.
- Bind-mounted jails still active after restart
  (`Using Mount Namespaces: true`, jail setup ~6 ms).

## Prevention
- **Never upload a hunspell dictionary as a wordbook.** Wordbooks (Nextcloud
  Office → personal settings) are for small personal word lists; language
  spellcheck comes from the `dictionaries` env on the CODE container.
- The manifest now documents *why* each security setting exists, so a future
  cleanup doesn't regress jail setup to the copy path.
- Methodological (the expensive lesson): **two pathologies overlapped and the
  visible one was mistaken for the cause.** "X happens during the slow window"
  is correlation; only the intervention (fix X, re-measure) proves causation.
- Worth an upstream issue: richdocuments accepted a 588 KB wordbook upload
  with no sanity check, and CODE loads wordbooks quadratically. Artifacts:
  `~/backup-English-British.dic.bak` + perf profile in the v3 log.

## Related
- Raw investigation logs: [v2](collabora-slow-load-investigation-v2.md) ·
  [v3](collabora-slow-load-investigation-v3.md) (includes corrections register)
- `k8s/apps/collabora/deployment.yaml` — commented security/config choices
- `docs/reference/capacity-headroom.md` — Collabora sizing (unrelated to incident)
- Upstream context: CollaboraOnline/online#14087 (different trigger, same
  jail-copy fallback family)
