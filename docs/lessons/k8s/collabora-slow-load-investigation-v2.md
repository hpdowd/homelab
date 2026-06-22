# Collabora CODE: slow cold document load (auditable investigation log)

*Homelab k3s cluster · namespace `collabora` · pod pinned to `k3s-worker1`*

## How to read this document

Every conclusion below is tagged with the evidence it rests on so it can be
re-audited. Tags:

- **[FACT]:** directly observed in a command output or log line (quoted/derived).
- **[INFERENCE]:** reasoning from facts; may be wrong; the reasoning is shown.
- **[UNRESOLVED]:** a known gap or tension that is *not* yet explained.
- **[CORRECTION]:** something asserted earlier in the investigation that was later
  shown wrong; recorded so it is not re-trusted.

The goal is that the next reader can challenge any **[INFERENCE]** against the
**[FACT]** lines, and is warned about every **[UNRESOLVED]** point rather than
inheriting a clean-looking but unproven story.

---

## 1. Symptom [FACT]

- Cold open of a document (not already open in another session): editor frame appears
  ~7 s; document becomes **editable at ~55 s**.
- Measured twice, docx and xlsx: both ~55 s, near-identical.
- pptx: slower still (not timed precisely).
- **A file already open in another browser tab opens practically instantly**, and the
  server reports 2 editing instances.

---

## 2. Environment (context for decisions)

- k3s: control VM `192.168.1.10` (RAM-starved, ~3.5GiB), worker `k3s-worker1`
  `192.168.1.11` (14GiB). Collabora pinned to worker via nodeAffinity. [FACT, from setup]
- Ingress: Traefik (MetalLB `192.168.1.200`), `ingressClassName: traefik`, no
  entrypoints annotation. Wildcard DNS `*.henrydowd.dev → 192.168.1.200`.
- Public exposure: Cloudflare tunnel, wildcard `*.henrydowd.dev`. TLS terminated at
  Cloudflare; cloudflared → Traefik over plain HTTP.
- Traefik currently serves a **self-signed** cert on the direct/LAN path (cert-manager
  DNS-01 not yet done). This is why the pod was given a public-DNS hairpin (see config).

## 3. Current applied config (confirmed unless noted)

- **Image:** `collabora/code:25.04.10.3.1` (downgraded from `26.04.1.4.1` during
  investigation). [FACT, user applied]
- **securityContext.capabilities.add:** `["SYS_ADMIN","MKNOD","SYS_CHROOT","FOWNER"]`
  [FACT, `kubectl get pod ... -o jsonpath` returned `{"add":["SYS_ADMIN","MKNOD","SYS_CHROOT","FOWNER"]}`]
- **AppArmor:** `unconfined` via
  `container.apparmor.security.beta.kubernetes.io/code: unconfined`. [FACT, applied]
- **extra_params (current):** `--o:ssl.enable=false --o:ssl.termination=true --o:logging.level=trace`
  [FACT, user pasted this exact value]
  - **[CORRECTION]** `--o:mount_namespaces=false` is **NOT** in the current params.
    It was present early in the build and was removed. At one point during the
    investigation it was claimed to be the cause of the copy behaviour, **that claim
    was wrong** (the user confirmed the flag was already absent when the copy was still
    happening). Do not reintroduce or blame this flag.
- **dnsPolicy:** `None`; **dnsConfig.nameservers:** `[1.1.1.1, 1.0.0.1]`. [FACT, in manifest]
  - Purpose: make the WOPI reachback resolve the *public* Nextcloud name to the
    Cloudflare edge so it gets a valid cert instead of Traefik's self-signed one.
- **Probes (current):** Startup `httpGet /hosting/discovery` (failureThreshold reduced
  to 30); Readiness `httpGet /hosting/discovery`; Liveness `tcpSocket :9980`.
  [FACT, `kubectl describe pod`]
- **Nextcloud richdocuments:** `wopi_url = http://collabora.collabora.svc.cluster.local:9980`
  (in-cluster, plain HTTP); `public_wopi_url = https://collabora.henrydowd.dev`.
  [FACT, occ output]
- **Suggested but NOT confirmed applied:** `dictionaries=en_GB en_US`,
  `--o:num_prespawn_children=3`. Not present in the pasted params; treat as not applied.

---

## 4. Evidence log (raw measurements)

### 4.1 Resource usage during a cold open [FACT]
- `kubectl top pod`: memory ~370–436Mi, **flat** across the whole load.
- `kubectl top pod`: CPU climbs **linearly ~2m → ~1000m** (one full core), then holds
  ~1000m for roughly the final 10 s before editable. (Sampled ~every 15–20 s, so 3–4
  points across the load; all consistent with a linear climb to a 1-core ceiling.)
- `kubectl top nodes`: worker ~42% memory (~6GB/14GiB), CPU ~3%.
- Restart count **0**; no OOMKill. [FACT, `kubectl get pods`, `describe`]

### 4.2 `serverloadtimings` line (trace log) [FACT]
Raw counters (microseconds), chronological:
```
wopiPostReceived   365343863400
checkFileInfoStart 365343863528
checkFileInfoEnd   365344045440
docBrokerCreated   365344045929
childRequested     365344084296
forkitSpawn        365344195684
jailSetupStart     365344195960
jailSetupEnd       365344359233
childAssigned      365344368154
presetsInstallStart 365344368897
wopiDownloadStart  365344368974
wopiDownloadEnd    365344575848
presetsInstallEnd  365347793643
loadDocumentStart  365347796044
loadDocumentEnd    365347845014
firstTileSent      365396309784
```
Derived phase durations:

| Phase | Duration | Note |
|---|---|---|
| checkFileInfo | ~182 ms | Nextcloud metadata call |
| jailSetup (this counter) | ~163 ms | **see UNRESOLVED 6.1** |
| wopiDownload (file fetch) | ~207 ms | fetch of file bytes |
| presetsInstall | ~3.42 s | |
| loadDocument | ~49 ms | the actual LO load |
| **loadDocumentEnd → firstTileSent** | **~48.46 s** | **dominant cost** |
| wopiPostReceived → firstTileSent | ~52.45 s | ≈ wall clock (+client ≈55s) |

Also in this log block [FACT]: the kit's document URL is the **public** name,
`https://nextcloud.henrydowd.dev:443/index.php/apps/richdocuments/wopi/files/5192_...`,
i.e. the file fetch used the public/hairpin path and still completed in ~207 ms.

### 4.3 Process attribution via `/proc/[pid]/stat` during the uneditable window [FACT]
- At the start of the open: `coolwsd` is the top CPU consumer.
- During the long uneditable period: **`coolforkit-caps` is the top CPU consumer and
  its accumulated CPU climbs continuously** until the doc opens (sampled values rose
  3933 → 4400 → 4913 jiffies across successive reads).
- cmdline: `/usr/bin/coolforkit-caps --systemplate=/opt/cool/systemplate
  --lotemplate=/opt/collaboraoffice --childroot=/opt/cool/child-roots/1-.../ ...`

### 4.4 Jail construction path (trace log, verbatim) [FACT]
```
[ kit_spare_016 ] INF  Mounting is disabled, will link/copy /opt/cool/systemplate -> /opt/cool/child-roots/1-.../   | kit/Kit.cpp:3648
[ kit_spare_016 ] INF  linkOrCopy all from [/opt/cool/systemplate] to [...]                                        | kit/Kit.cpp:600
[ kit_spare_016 ] INF  linkOrCopy LibreOffice from [/opt/collaboraoffice] to [.../lo/]                             | kit/Kit.cpp:600
```
Persistent warning present throughout [FACT]:
```
[ forkit ] WRN The systemplate directory [/opt/cool/systemplate] is read-only ... Will have to clone dynamic elements of systemplate to the jails. | common/JailUtil.cpp:628
```

### 4.5 Capabilities at runtime, `/proc/1/status` [FACT]
```
CapEff: 0000000000000000      (effective set EMPTY)
CapBnd: 00000000a82425fb      (bounding set includes requested caps)
```
- `CapEff` was **still `0`** after AppArmor was set to `unconfined`.
- AppArmor profile before unconfining: `cri-containerd.apparmor.d (enforce)`
  (`/proc/1/attr/current`).

### 4.6 Network path measurements [FACT]
- 20× curl loop, workstation → Traefik `192.168.1.200`, Host `collabora.henrydowd.dev`,
  `/hosting/discovery`: all `200`, ~13 ms each, stable.
- In-pod reachback to `https://nextcloud.henrydowd.dev/status.php` via the CF hairpin
  (throwaway pod with same dnsConfig): 5× `200`, ~100 ms each, stable.
- `wopiDownload` in §4.2: ~207 ms.

### 4.7 `.lan` / cert observations [FACT]
- Setting `wopi_url=https://collabora.lan` → occ `activate-config` failed:
  `cURL error 60: SSL certificate problem: self-signed certificate` for
  `https://collabora.lan/hosting/discovery`.
- Setting `wopi_url=https://collabora.henrydowd.dev` (public, TLS) → occ failed:
  `cURL error 28: Operation timed out after 5000ms with 0 bytes received`.
- Setting `wopi_url=http://collabora.collabora.svc.cluster.local:9980` (in-cluster
  HTTP) → this is the current working value for the discovery direction.

### 4.8 coolmount history [FACT]
- Before `SYS_ADMIN` was added to the manifest: repeated
  `sh: 1: /usr/bin/coolmount: Operation not permitted`.
- After `SYS_ADMIN` (and MKNOD/SYS_CHROOT/FOWNER) were added: those `coolmount` lines
  **stopped appearing**.

---

## 5. Hypotheses considered, with the evidence that decided each

| # | Hypothesis | Why considered | Evidence | Verdict |
|---|---|---|---|---|
| H1 | Readiness probe flapping pulls pod from Service | "temperamental" opens | Pod stays `Ready 1/1`, **0 restarts** (§4.1); 20× stable curl (§4.6) | **REJECTED** [FACT] |
| H2 | Cloudflare reachback latency is the cost | slow + hairpin in path | `wopiDownload`=207 ms (§4.2); hairpin 100 ms, LAN 13 ms (§4.6) | **REJECTED as dominant cost** [FACT] — 207 ms cannot explain 48 s |
| H3 | Memory pressure / OOM thrash | "fast then degrades" | mem flat ~370Mi, worker 42%, **0 restarts** (§4.1) | **REJECTED** [FACT] |
| H4 | New-major image regression (`26.04.1.4.1`) | first release of a major | downgrade to `25.04.10.3.1` → **identical** ~55 s | **REJECTED** [FACT] |
| H5 | fontconfig/`fc-cache` rebuild per jail | ~48 s ≈ cold fc-cache | `/proc` top process is `coolforkit-caps`, **not** fc-cache/soffice (§4.3) | **REJECTED** [FACT] |
| H6 | AppArmor blocks the mount syscall | enforce profile present | set `unconfined` → `CapEff` still `0` (§4.5) | **REJECTED as sole cause** [FACT] |
| H7 | `--o:mount_namespaces=false` forces copy | flag seen earlier | flag **not present** when copy still occurred (§3 CORRECTION) | **REJECTED** [FACT/CORRECTION] |

---

## 6. Unresolved gaps the next model MUST account for

### 6.1 [UNRESOLVED] Which operation the 48 s actually maps to
- §4.2 attributes the gap to **`loadDocumentEnd → firstTileSent`** (a post-load /
  first-tile phase), and the line's own `jailSetup` counter is only ~163 ms.
- §4.3/§4.4 show the pegged process is **`coolforkit-caps`** doing a **link/copy** of
  the systemplate + LibreOffice tree.
- These have **not been reconciled on a single timeline.** It is an [INFERENCE], not a
  proven fact, that the 48 s is the copy. It is plausible the copy (spare-kit
  preparation) overlaps/blocks the pipeline such that the "first tile" can't be sent
  until a copied jail is ready, but the timestamps of the `linkOrCopy` log lines were
  **not** measured against the 48 s window.
- **Check to resolve:** on a cold open, capture timestamps of the `Mounting is
  disabled` / `linkOrCopy ...` lines and compare their span to the
  `loadDocumentEnd → firstTileSent` gap. If the copy spans ~48 s, the copy theory is
  confirmed. If the copy is quick and 48 s elapses *after* it, the cost is elsewhere
  (e.g. rendering) and the cap/copy story is NOT the root cause.

### 6.2 [UNRESOLVED] coolmount errors stopped, yet `CapEff` is `0`
- §4.8: `coolmount: Operation not permitted` stopped after caps were *requested*.
- §4.5: but `CapEff` is empty, so the cap is not effective at pid 1.
- Why the error stopped if the cap is not effective is **not explained.** Possible
  reasons (unverified): CODE stopped *attempting* the mount and switched to a clean
  copy path once caps were requested; or coolmount/coolforkit carry file capabilities
  independent of pid 1's `CapEff`; or effective caps differ in the child process from
  pid 1. The next model should **not** assume "the cap is entirely ineffective", only
  that **pid 1's `CapEff` is 0**, which is the measured fact.

---

## 7. Leading hypothesis (reasoning chain, each link tagged)

Chain:
1. [FACT §4.4] CODE logs `Mounting is disabled, will link/copy` and performs
   `linkOrCopy` of the systemplate + LibreOffice tree per cold jail.
2. [FACT §4.3] `coolforkit-caps` (the jail builder) is the pegged CPU consumer during
   the uneditable window.
3. [FACT §4.5] pid 1 `CapEff = 0`; `SYS_ADMIN` is in `CapBnd` but not effective.
4. [INFERENCE] Mounting is disabled **because** the process lacks an effective
   `CAP_SYS_ADMIN`; without mount, CODE falls back to the slow recursive copy.
5. [INFERENCE] The recursive copy is single-threaded and large (LO tree), consistent
   with a 1-core peg (§4.1) and a multi-tens-of-seconds duration.
6. [INFERENCE, suspected mechanism, UNVERIFIED] `CapEff` is empty because the image's
   entrypoint **drops from root to the `cool` user**, and effective capabilities are
   not retained across a uid change unless set as *ambient* caps, which the image does
   not set.

Confidence: links 1–3 are facts; link 4 is well-supported; link 5 depends on §6.1
being resolved; link 6 is **unverified** (the suspected cause of the empty `CapEff`).

### Checks that confirm or refute the chain
- **§6.1 timestamp check** (copy span vs 48 s gap), confirms/refutes that the copy is
  the cost (links 4–5).
- **uid-drop check** (link 6):
  ```
  kubectl exec -n collabora deploy/collabora -- sh -c 'grep -E "^(Uid|Gid)" /proc/1/status'
  ```
  Non-zero Uid supports the uid-drop mechanism. (Not yet run.)

---

## 8. Candidate fix + verification plan (NOT yet applied)

Candidate: set container `securityContext.privileged: true` (keeps the explicit
capability list for documentation). Rationale [INFERENCE]: privileged forces a full
effective cap set that survives the uid drop, so coolforkit can mount instead of copy.

This is a candidate, **contingent on §6.1 confirming the copy is the cost.** If §6.1
shows the 48 s is *after* the copy (rendering-bound), privileged will not help and the
investigation should pivot to the first-tile/render phase.

Verify, in order, after applying:
1. `kubectl exec ... grep CapEff /proc/1/status` → expect non-zero.
2. Cold-open log → expect `Bind-mounting`, **absence** of `Mounting is disabled`.
3. Time a cold open → expect a few seconds, not ~55 s.

If `CapEff` stays `0` even under privileged, the uid-drop/ambient-cap theory needs
revisiting (e.g. the entrypoint, `runAsUser`, ambient cap configuration).

---

## 9. Separate, non-blocking follow-ups
- Remove `--o:logging.level=trace` after debugging (firehose).
- cert-manager DNS-01 for a real `*.henrydowd.dev` cert on Traefik would let the
  `dnsPolicy/dnsConfig` hairpin be removed and clear the `.lan` self-signed warnings
  (§4.7). Independent of the slow-load issue; do **not** conflate the two.
