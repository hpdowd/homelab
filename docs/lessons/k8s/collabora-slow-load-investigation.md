# Collabora CODE: slow cold document load (auditable investigation log)

*Homelab k3s cluster · namespace `collabora` · pod pinned to `k3s-worker1`*

> **RESOLVED 2026-06-11: H11 confirmed and fixed. See §11.** Root cause: a
> 588 KB / 51,573-entry hunspell `en_GB.dic` had been uploaded as the personal
> *wordbook* for user `henry` in Nextcloud Office settings
> (`appdata_*/richdocuments/userconfig/henry/wordbook/English (British).dic`,
> dated 2026-04-01). CODE's presets mechanism installed it into every cold kit
> jail and `DictionaryNeo` sort-inserted all 51k entries before first tile.
> File backed up to `~/backup-English-British.dic.bak` (moved out of the repo), deleted
> from appdata, file cache rescanned, pod restarted. Awaiting final cold-open
> timing by user.

## How to read this document

Every conclusion is tagged with the evidence it rests on so it can be
re-audited:

- **[FACT]:** directly observed in command output or log lines (quoted/derived).
- **[INFERENCE]:** reasoning from facts; may be wrong; reasoning shown.
- **[UNRESOLVED]:** a known gap that is *not* yet explained.
- **[CORRECTION]:** something asserted earlier and later shown wrong; recorded
  so it is not re-trusted.
- **[REFUTED]:** a previously-leading theory disproven by experiment.

The single most important methodological lesson of this investigation so far:
**two pathologies overlapped in time and one was mistaken for the cause of the
other.** The jail-copy fallback was real, expensive, and fixable, and fixing
it changed nothing about the symptom. Treat any remaining "X happens during the
slow window" observation as correlation until an intervention proves causation.

---

## 1. Symptom [FACT, unchanged through all interventions]

- Cold open of a document: editor frame ~7 s; **editable at ~55 s**.
- docx and xlsx near-identical (~55 s, measured repeatedly across weeks,
  two CODE major versions, and the jail-mount fix). pptx slower (untimed).
- A document already open in another session opens practically instantly.
- The near-perfect constancy across document type/size and software versions
  is itself evidence: the cost is **fixed per-kit work**, not proportional to
  document content. [INFERENCE, well-supported]

## 2. Environment

- k3s v1.35.5+k3s1, containerd 2.2.3-k3s1. Control VM `192.168.1.10`
  (Debian 13, ~3.5 GiB RAM), worker `k3s-worker1` VM 301 `192.168.1.11`
  (Debian 13 trixie, kernel 6.12.90, 14 GiB). [FACT, `kubectl get nodes -o wide`]
- **Worker vCPU model: `x86-64-v2-AES`** (`qm config 301`), presenting in-guest
  as `QEMU Virtual CPU version 2.5+`, **no AVX/AVX2**. [FACT]
  - x86-64-v2 tops out at SSE4.2. The host (i5-14500T) supports x86-64-v3.
    A generic vCPU model also causes the guest kernel to apply worst-case
    speculative-execution mitigations. [FACT re flags; INFERENCE re mitigations
    impact, magnitude unmeasured]
- Ingress: Traefik (MetalLB `192.168.1.200`); Cloudflare tunnel for WAN; WOPI
  discovery direction uses in-cluster HTTP
  (`wopi_url = http://collabora.collabora.svc.cluster.local:9980`); kit
  reachback uses public name via `dnsPolicy: None` + public resolvers. [FACT]

## 3. Current applied config

Repo (`k8s/apps/collabora/deployment.yaml`, ArgoCD-managed) [FACT]:

- Image `collabora/code:25.04.10.3.1`.
- `securityContext.appArmorProfile: { type: Unconfined }`, **the field, not
  the deprecated annotation** (this distinction turned out to be load-bearing;
  see §5.1).
- `capabilities.add: [SYS_ADMIN, MKNOD, SYS_CHROOT, FOWNER, CHOWN]`.
- `extra_params: --o:ssl.enable=false --o:ssl.termination=true` (no logging
  flag in repo).
- `dictionaries: en_GB en_US` (hunspell selection, NOT the same subsystem as
  the wordbooks in §7).
- dnsPolicy None / Cloudflare resolvers; probes as before.

**[UNRESOLVED U7: config hygiene]** The live pod at 2026-06-11 01:15 emitted
`TRC`-level log lines although the repo `extra_params` contains no logging
flag. Live deployment and Git may have diverged (manual edit for debugging?).
Check `kubectl get application collabora -n argocd -o jsonpath='{.status.sync.status}'`
and the live container env, reconcile before final measurements, trace
logging is itself a per-tile cost and contaminates timings.

---

## 4. Evidence from the pre-fix phase [FACT]

- `serverloadtimings` (trace, pre-fix). Raw counters (microseconds),
  chronological:
  ```
  wopiPostReceived    365343863400
  checkFileInfoStart  365343863528
  checkFileInfoEnd    365344045440
  docBrokerCreated    365344045929
  childRequested      365344084296
  forkitSpawn         365344195684
  jailSetupStart      365344195960
  jailSetupEnd        365344359233
  childAssigned       365344368154
  presetsInstallStart 365344368897
  wopiDownloadStart   365344368974
  wopiDownloadEnd     365344575848
  presetsInstallEnd   365347793643
  loadDocumentStart   365347796044
  loadDocumentEnd     365347845014
  firstTileSent       365396309784
  ```
  Derived: checkFileInfo ~182 ms · jailSetup counter ~163 ms ·
  wopiDownload ~207 ms · **presetsInstall ~3.42 s** · loadDocument ~49 ms ·
  **loadDocumentEnd → firstTileSent ~48.46 s** (the dominant gap);
  wopiPostReceived → firstTileSent ~52.45 s ≈ wall clock (+client ≈55 s).
  NOTE: these counters are WSD-side dispatch times; see §7. The kit's document
  URL in this same log block was the **public** name (hairpin path) and the
  file fetch still completed in ~207 ms.
- Network path: WOPI reachback ~100–207 ms; LAN discovery ~13 ms; all stable.
  H2 (network latency as dominant cost) remains REJECTED.
- No restarts, no OOM, flat memory ~370–436 Mi, worker node not memory-pressed.
  H1 (probe flapping) and H3 (memory pressure) remain REJECTED.
- Image downgrade `26.04.1.4.1 → 25.04.10.3.1`: no change. H4 remains REJECTED.
- During the slow window, exactly one process accumulates CPU linearly to a
  1-core ceiling (~2 m → ~1000 m), then ~10 s plateau before editable.

## 5. New evidence (this session, chronological)

### 5.1 AppArmor / capabilities resolution [FACT]

- `kubectl exec … cat /proc/1/attr/current` → `unconfined`
  (with the `appArmorProfile` **field** applied; previously
  `cri-containerd.apparmor.d (enforce)` under the **annotation** attempt).
- `getcap`:
  - `/usr/bin/coolmount cap_sys_admin=ep`
  - `/usr/bin/coolforkit-caps cap_chown,cap_fowner,cap_sys_chroot=ep`
- Mechanism [INFERENCE, strongly supported]: CODE's privilege model uses
  **file capabilities** on helper binaries. These activate at exec() provided
  the capability is in the process's **bounding set** (supplied by the pod's
  capability list). pid 1's `CapEff = 0` is the *expected healthy state*,
  coolwsd runs as the unprivileged `cool` user.
- This resolves the earlier `CapEff`/`coolmount` puzzle entirely: the
  `coolmount: Operation not permitted`
  errors stopped when the bounding set gained the caps; the *mount self-test*
  still failed only because the **default `cri-containerd.apparmor.d` profile
  denies the `mount(2)` syscall regardless of capabilities**, and the
  annotation-based "unconfined" never applied on k3s v1.35 (annotation
  deprecated since K8s 1.30 in favour of the field). [INFERENCE for the deny
  mechanism, consistent with all observations and with public reports of the
  same failure family, e.g. CollaboraOnline/online#14087 (a different trigger,
  uid-65534 self-test, same fallback behaviour); FACT that field works and
  annotation state showed enforce]

### 5.2 Mount fix verified: jail copy ELIMINATED [FACT]

Restart at 2026-06-11 01:15, startup log:

```
INF  Creating childroot: [...] with mount-namespaces
TRC  Bind-mounted [/opt/cool/systemplate] -> [...cool_test_mount]
INF  Using Bind Mounting: true
INF  Using Mount Namespaces: true
```

Kit jail construction is now a handful of bind mounts; the kit's own
handshake reports `adms_bindmounted=ok … adms_info_setup_ms=6
… adms_info_namespaces=true`. Jail setup: **6 ms** (was ~48 s of copying).
Note the jail mounts the LO tree at a *different internal path*:
`/opt/collaboraoffice -> <jail>/lo/`.

### 5.3 Symptom retest after mount fix [FACT] → copy-fallback theory REFUTED

Cold open re-measured with bind-mounted jails: **still ~55 s, unchanged.**

- **[REFUTED]** The earlier leading hypothesis (copy fallback as cause of the
  55 s symptom). The copy was a real, coincident pathology.
- **[REFUTED]** The earlier candidate fix (`privileged: true`), built on the
  invalid `CapEff` reasoning (§5.1) and now moot.
- The earlier open question of reconciling the 48 s gap with the copy is
  thereby resolved by experiment: they were **not** causally linked.

### 5.4 Process attribution, post-fix [FACT]

`/proc/[pid]/stat` sampling during a cold open (USER_HZ=100, so jiffies ≈ cs):

```
3578 181 kitbroker_015 R 0          ← document's kit; ~35.8 s CPU and climbing
 433   1 coolwsd       S do_sys_poll
 132  23 forkit        S do_sys_poll ← ~1.3 s CPU over entire pod lifetime
   6 124 kit_spare_010 S do_sys_poll ← spares ~0.05 s each (cheap forks)
   5 149 subforkit_001 S do_sys_poll
```

Key deductions:
- The burner is **the kit assigned to the document** (kits rename
  `kit_spare_N` → `kitbroker_N` on assignment), in userspace (`R`, wchan 0).
- **forkit's lifetime CPU is ~1.3 s** → the expensive work is NOT general
  LO initialization at pod start (preinit would have paid it once in forkit).
  It is **triggered per document load, inside the kit**. [INFERENCE, strong]
- A `subforkit_001` exists, part of the 25.04 per-config/presets machinery.
  Its role here is uncharacterized. [FACT of existence; UNRESOLVED U5]

### 5.5 I/O accounting during the burn [FACT]

For the busy kit: `read_bytes: 0`; `rchar` grew ~515 KB → ~1.4 MB across the
window, then stopped. Persistent fds: `/dev/urandom`, `types.rdb`,
`offapi.rdb`, `oovbaapi.rdb`, `th_en_US_v2.dat` (UNO type registries +
thesaurus, long-lived, unremarkable).

- The work is **pure computation**, not file scanning at the read() level.
- **[CORRECTION]** An intermediate claim that `read_bytes: 0` "formally killed"
  the font hypothesis was overstated: mmap'd reads (FreeType's access pattern)
  are invisible to these counters, and 2 s fd snapshots miss transient fds.
  Fonts were properly excluded only by §5.7 (no FreeType/fontconfig/harfbuzz
  symbols in the profile).
- No sockets in `SYN_SENT` during the window → no connect-timeout component.
  The wait/timeout hypothesis class is REJECTED. [FACT]

### 5.6 Font environment [FACT]

`/opt/collaboraoffice/share/fonts` = 185 MB; `/usr/share/fonts` = 3.3 MB;
fontconfig caches present: 7 in container rootfs, 7 in systemplate.
(With §5.7, fonts are excluded as the hot path; recorded for completeness.)

### 5.7 CPU profile of the burning kit [FACT, decisive but thin]

`perf record -F 99 -g -p <kitbroker> -- sleep 30` on the worker VM
(possible because kit processes are visible in the VM PID namespace and the
CODE build ships `--enable-symbols`):

```
26.32%  libmergedlo.so   DictionaryNeo::cmpDicEntry(u16string_view, u16string_view, bool)
21.05%  libuno_sal.so.3  rtl_uString_acquire
21.05%  libuno_sal.so.3  rtl::str::release<_rtl_uString>
10.53%  libmergedlo.so   DictionaryNeo::isSorted()
 5.26%  libstdc++        _Prime_rehash_policy::_M_need_rehash
```

≈ 79% of samples in **`DictionaryNeo`** (LibreOffice's wordbook / user
dictionary implementation: parses `.dic` wordbook files, maintains sorted
entry order, `cmpDicEntry` is the entry comparator) and the `rtl_uString`
refcount churn those comparisons generate.

**Capture-quality caveat [FACT]:** only **19 samples** (~0.19 s of CPU at
99 Hz) were collected, the attach raced the burn window (or attached to a
near-idle/previous kitbroker and caught only a sliver of activity). The
symbol pattern is internally coherent and highly specific, so the
*direction* is trusted; the *percentages* are not. Re-capture required
(§8 item 1).

---

## 6. Hypothesis table (cumulative, updated)

| # | Hypothesis | Evidence | Verdict |
|---|---|---|---|
| H1 | Readiness probe flapping | 0 restarts; stable LAN curls | REJECTED [FACT] |
| H2 | Cloudflare/WOPI reachback latency | wopiDownload 207 ms vs 48 s gap | REJECTED [FACT] |
| H3 | Memory pressure / OOM | flat RSS, no restarts | REJECTED [FACT] |
| H4 | Image-version regression | identical on 25.04 & 26.04 | REJECTED [FACT] |
| H5 | fontconfig/`fc-cache` rebuild per jail | v2 rejection was on unsound evidence (process-name + io-counter blindness to mmap); properly rejected by perf: no FreeType/fontconfig symbols | REJECTED [FACT via §5.7, with §5.7 caveat] |
| H6 | AppArmor blocks mount | v2 rejected it on an invalid test (`CapEff`); reinstated and CONFIRMED as cause of the **copy fallback** (not of the symptom) | CONFIRMED for copy; copy itself REFUTED as symptom cause |
| H7 | `--o:mount_namespaces=false` | flag absent while copy occurred | REJECTED [CORRECTION, from v2] |
| H8 | Jail copy is the 55 s cost | copy eliminated (6 ms), symptom unchanged | **REFUTED by experiment** [FACT] |
| H9 | Network wait / connect timeout | R-state CPU burn; no SYN_SENT | REJECTED [FACT] |
| H10 | General per-kit LO init (preinit broken) | forkit lifetime CPU 1.3 s; burn is load-triggered | REJECTED as stated [FACT-based] |
| **H11** | **Wordbook (`DictionaryNeo`) load/sort at document load** | §5.7 profile; presets mechanism (§7) | **LEADING — confirmation pending** |
| H12 | vCPU model (`x86-64-v2-AES`) as multiplier | no AVX2; generic model → worst-case mitigations | OPEN — cheap experiment queued (§8 item 4) |

## 7. Leading hypothesis (chain, each link tagged)

1. [FACT §5.7] During the slow window the document's kit spends its CPU in
   `DictionaryNeo::cmpDicEntry` / `isSorted` + string refcounting.
2. [FACT] `DictionaryNeo` is the LO implementation of **wordbooks** (user/
   custom dictionaries, `.dic` files in the user profile, e.g. `standard.dic`,
   ignore-lists), distinct from hunspell language dictionaries (the
   `dictionaries=en_GB en_US` env var is hunspell and unrelated).
3. [FACT, §4] The original timings include a `presetsInstall` phase
   (~3.42 s), CODE 25.04's mechanism for downloading per-user/system presets
   **from the WOPI host (Nextcloud richdocuments)** into the kit's jail at
   document-load time. Presets include wordbooks. The `subforkit` machinery
   (§5.4) belongs to the same feature.
4. [INFERENCE] A wordbook delivered via presets (or shipped in the profile) is
   parsed and sorted by `DictionaryNeo` on first spellcheck during initial
   layout/render, i.e. *after* `loadDocumentEnd` (a WSD-side dispatch
   timestamp) and *before* `firstTileSent`, exactly where the 48 s gap sits.
5. [INFERENCE] The duration implies a pathological input or algorithm:
   an oversized wordbook, a malformed file parsed as an enormous entry list,
   or an unsorted wordbook triggering comparison-heavy (potentially quadratic)
   insertion. The ~3.4 s `presetsInstall` (download/install only) is itself
   suspiciously large for what should be tiny files, consistent with a large
   payload.
6. [OPEN, H12] The crippled vCPU may multiply whatever n is involved; it is
   unlikely to be the sole cause of a 48 s fixed cost but could turn "annoying"
   into "55 seconds".

Confidence: links 1–3 fact; 4–5 inference pending §8 confirmations. The
profile's thin sample count (§5.7 caveat) is the main residual risk to link 1's
percentages (not to the symbol identification itself).

### Unresolved register

- **U1** Identity, size, and origin of the wordbook(s) `DictionaryNeo` is
  loading: preset-downloaded from Nextcloud vs shipped in the jail profile?
- **U2** perf capture quality: 19 samples; needs a verified full-window
  capture.
- **U3** Mechanism of the ~48 s: n (size) vs algorithm (unsorted/quadratic) vs
  vCPU multiplier; also re-confirm post-fix that the gap still sits at
  `loadDocumentEnd → firstTileSent` (fresh `serverloadtimings` needed, the
  old one predates the mount fix).
- **U4** H12 experiment not yet run (`cpu: host`).
- **U5** Role of `subforkit_001`: one per configId? Created per user? Does a
  *new* subforkit appear per cold open?
- **U6** Why pptx is slower still (minor; revisit after root cause).
- **U7** Live-pod vs Git config divergence (trace logging), §3.

## 8. Next data to collect (exact commands, in priority order)

1. **Verified full-window perf capture** (on `k3s-worker1`, arm BEFORE the
   open; expect thousands of samples, if you again get <100, the attach
   raced and you should use the system-wide variant below):
   ```bash
   while ! pgrep kitbroker >/dev/null; do sleep 0.1; done
   sudo perf record -F 199 -g -p "$(pgrep kitbroker | head -1)" -- sleep 60
   sudo perf report --stdio --percent-limit 1 | head -80
   # fallback, system-wide, filter afterwards:
   # sudo perf record -F 199 -g -a -- sleep 60
   # sudo perf report --stdio --percent-limit 1 --comms "$(pgrep -l kitbroker | awk '{print $2}')"
   ```
2. **Wordbook inventory in a live jail** (run immediately after a cold open,
   while the document is still open):
   ```bash
   kubectl exec -n collabora deploy/collabora -- sh -c '
     find /opt/cool/child-roots -name "*.dic" -exec ls -la {} \; 2>/dev/null
     echo ---
     find /opt/cool/child-roots -ipath "*wordbook*" -exec ls -la {} \; 2>/dev/null
     echo ---
     find /opt/cool/child-roots -ipath "*preset*" -exec ls -lad {} \; 2>/dev/null'
   ```
   For any non-trivial `.dic`: `wc -l` it and `head -5` it (header should be a
   short `OOoUserDict1`-style preamble; megabytes or six-figure line counts
   are the smoking gun).
3. **Preset download trail.** Temporarily set
   `--o:logging.level=debug` (NOT trace), cold-open, and capture:
   ```bash
   kubectl logs -n collabora deploy/collabora --since=5m \
     | grep -iE "preset|wordbook|dictionar|\.dic|subforkit|configid"
   kubectl logs -n collabora deploy/collabora --since=5m | grep serverloadtimings
   ```
   The fresh `serverloadtimings` line doubles as the U3 gap-location check.
4. **Nextcloud side of the presets:**
   ```bash
   occ config:list richdocuments
   occ user:setting <uid> richdocuments
   ```
   plus UI: Personal settings → Nextcloud Office (personal wordbook) and
   Administration → Office (system-wide wordbook / Advanced settings). Note
   sizes/entry counts of anything found.
5. **Control experiment (cheap, high signal):** create a fresh Nextcloud user
   with no personal settings; cold-open the same file as that user.
   - Fast → per-user preset implicated (Henry's wordbook).
   - Equally slow → system-wide preset or shipped profile content.
6. **H12 experiment:** `qm shutdown 301 && qm set 301 --cpu host && qm start 301`
   (full stop/start required; pods on the worker restart; Longhorn volumes
   reattach). Verify in-guest `model name` shows the 14500T, re-time a cold
   open. Do VM 300 as well while at it. This is the correct production setting
   for a single-node Proxmox regardless of outcome.

## 9. Candidate fixes (contingent on §8)

- **If a preset wordbook is oversized/malformed:** clear or repair it in
  Nextcloud (personal and/or admin Office settings); re-time. If the payload
  was garbage (e.g. a non-dictionary file served as a wordbook), file an
  upstream issue against richdocuments/CollaboraOnline with the perf profile
  and the offending file, strong portfolio artifact.
- **If preset sync itself is the problem and no content fix exists:** look for
  a richdocuments/coolwsd toggle to disable wordbook preset sync; document the
  trade-off (no personal dictionaries in-editor).
- **If H12 dominates:** `cpu: host` is the fix; record before/after numbers.
- **Independent of root cause, already justified:**
  - Keep the AppArmor-field + file-caps configuration (jail setup 6 ms).
  - After the symptom is fixed, add `--o:num_prespawn_children=2` (spares are
    nearly free with bind-mounted jails).
  - Resolve U7 (Git/live divergence) and drop any debug logging.
  - Consider the leaner-caps experiment: with namespace mounting active
    (`adms_info_namespaces=true`), `SYS_ADMIN` may be droppable, test by
    removing it and confirming `Using Mount Namespaces: true` survives a
    restart.

## 10. Corrections register (do not re-trust)

- **C1** (earlier): `--o:mount_namespaces=false` blamed for the copy, wrong;
  flag was absent while copying occurred.
- **C2** (earlier): "AppArmor rejected as sole cause", the rejection test
  (`CapEff` after annotation change) was invalid twice over: the annotation
  never applied, and `CapEff=0` at pid 1 is the healthy state under the
  file-capabilities model. AppArmor *was* the cause of the copy fallback.
- **C3** (earlier): copy-as-root-cause and `privileged: true` as fix, both
  refuted; the copy was coincident, and `privileged` would have "worked" only
  by disabling AppArmor as a side effect while teaching the wrong lesson.
- **C4** (this session): "`read_bytes: 0` formally excludes fonts",
  overclaimed; mmap'd I/O is invisible to those counters. Fonts were properly
  excluded only by the symbol profile.
- **C5** (earlier): "`coolforkit-caps` is the top consumer, therefore not
  fc-cache/soffice"; kit processes never exec a new binary (LO runs in-process
  under the forkit-derived name), so process-name attribution could not
  distinguish copying from any in-process LO work. The same blindness produced
  both the original copy attribution and the unsound H5 rejection.

---

## 11. Resolution (2026-06-11): H11 CONFIRMED, fix applied

### Evidence chain [FACT unless noted]

1. Nextcloud appdata inventory found
   `data/appdata_oc81lq0v51gk/richdocuments/userconfig/henry/wordbook/English (British).dic`,
   **587,750 bytes, 51,577 lines**, mtime 2026-04-01 11:12. The only other
   wordbook, `standard.dic`, is 300 bytes (35 genuine personal entries) and is
   untouched.
2. File content: `OOoUserDict1` wordbook header, then the line `51573`
   (a hunspell *entry-count* header, meaningless in a wordbook), then the full
   hunspell en_GB wordlist **including affix flags** (`éclat/M`, `émigré/S`,
   …). I.e. a raw hunspell `en_GB.dic` was uploaded as a personal wordbook,
   it provides zero spellcheck value in this form (en_GB hunspell is already
   active via `dictionaries=en_GB en_US`; flagged entries never match).
3. Mechanism [INFERENCE, strongly supported]: richdocuments serves user
   presets to CODE; the live jail showed the `sharedpresets` download tree for
   the system scope, and v2's `presetsInstall ~3.42 s` matches fetching the
   588 KB payload. On first spellcheck during initial layout (between
   `loadDocumentEnd` and `firstTileSent`), `DictionaryNeo` parses the file and
   sort-inserts 51,573 entries, comparison-quadratic on this input
   (~10⁹ `cmpDicEntry` calls + `rtl_uString` churn), matching the §5.7 perf
   profile, the 1-core peg, the fixed ~55 s independent of document type, and
   the instant second session (kit already paid the cost).
4. U7 resolved: live pod matches git HEAD (no trace logging live). The
   uncommitted working-tree edit adds `--o:logging.type=trace`, which is a
   typo anyway (`logging.level`); recommend discarding it.

### Fix applied

- Backed up to `~/backup-English-British.dic.bak` (587,750 bytes,
  verified byte count).
- Deleted the file from appdata; `occ files:scan-app-data richdocuments` run
  (clean); `standard.dic` retained.
- `kubectl rollout restart deploy/collabora` to flush kit/preset state; pod
  healthy, `/hosting/discovery` 200, bind-mounted jails still active.

### Remaining verification (user action)

- Cold-open a docx as henry → expect editable in a few seconds, not ~55 s.
- If still slow, next steps are unchanged: §8 item 1 (full-window perf) and
  §8 item 5 (fresh-user control).

### Still-open, non-blocking (from §8/§9)

- H12 / U4: vCPU `x86-64-v2-AES` → `cpu: host` on VMs 300/301 (correct
  setting regardless; was likely a multiplier on the quadratic burn).
- U5 (subforkit role), U6 (pptx delta), moot if retest is fast.
- After confirmed fast: add `--o:num_prespawn_children=2`; test dropping
  `SYS_ADMIN` while confirming `Using Mount Namespaces: true` survives.
- Guardrail idea: richdocuments accepted a 588 KB upload as a wordbook with
  no sanity check, and CODE loads it quadratically. Worth an upstream issue
  against richdocuments/CollaboraOnline with the perf profile + this file.
