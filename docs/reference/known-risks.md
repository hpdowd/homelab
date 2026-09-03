# Known Risks

Standing list of things that have not broken yet but are on a path to breaking, with the
evidence for each and what would stop it. Reviewed 2026-07-26 after the Longhorn
auto-salvage incident; §1 and §6 updated 2026-07-27 when the live fixes went in; §3 closed
and §1 revised 2026-08-10 when containerd and local-path moved off the worker's OS disk.

Ordered by expected damage, not by how likely they are.

---

## Open actions

Carried out of the 2026-07-25 incident review. The cluster is healthy, and item 1 — the one
that stood between the next reboot and a repeat of the 16-hour outage — was applied and
verified on 2026-07-27. Nothing remaining is an emergency.

| # | Action | Effort | Blocks | Risk |
|---|---|---|---|---|
| ~~1~~ | ~~Drop `storageReserved` on `/mnt/longhorn` to 10%~~ — **done 2026-07-27**, see §1 | — | — | — |
| ~~2~~ | ~~`site.yml --check --diff` and apply~~ — **done 2026-07-27**, see §6 | — | — | — |
| 3 | Route `severity: critical` to a channel that interrupts | ~1h | Needs you to pick ntfy/Gotify/Pushover | Low |
| ~~4~~ | ~~Remove the hand-added `[Journal]` block from the worker's `journald.conf`~~ — **done 2026-07-27**, now a role task | — | — | — |
| ~~5~~ | ~~Repoint local-path onto `vdb`~~ — **done 2026-08-10**, together with containerd, see §3 | — | — | — |
| 6 | Adopt `k8s/infrastructure/longhorn.yaml` | window | Volumes must be healthy | **Highest here.** Never mid-incident |
| 7 | Decide on worker memory limits at 191% of allocatable | judgement | — | Alert is currently ambient noise |
| 8 | Add a Longhorn `trim` recurring job | ~15 min | — | Low |
| 9 | Confirm the first restic prune actually ran (2026-07-27), then set the B2 bucket to keep last-version-only | ~10 min + a console change | Prune must run once first | Low; deletes only snapshots the 7d/4w/3m policy already excludes |
| 10 | Adopt `k8s/infrastructure/sealed-secrets.yaml` | window | Verify `kubeseal --fetch-cert` against the backup first | Moderate — the controller's key is the trust root for every secret in the repo |
| 11 | Exercise `bootstrap/bootstrap.sh` end-to-end against a scratch cluster | half a day | Needs a throwaway VM | None to prod; it is the only way to test the rebuild path |
| ~~12~~ | ~~Decide what happens to `home.dowd.ie`~~ — **done 2026-09-03**, host dropped from Traefik | — | — | — |

With items 1, 2, 4 and 5 closed, nothing left here carries ongoing exposure — but item 6 now
inherits part of it, because it is what makes the item 1 fix survive a rebuild (§1 below).
Item 6 is the one to be slowest about: it is the highest-value structural fix and the easiest
to do damage with. Item 9 is a verification, not a change, and it is the only one with a date
attached.

Item 5 is closed as of 2026-08-10 and took the worker's OS disk from 85% to 6% (§3). It also
changed §1's arithmetic: `vdb` is a shared disk now, so `storageReserved` went 49.1 → 80 GiB
to cover containerd and local-path. That makes item 6 slightly more load-bearing again —
there is one more hand-applied Longhorn setting for it to adopt.

Item 2 turned out to matter more than its "~30 min" suggested: running the playbook revealed
that the iSCSI shutdown ordering had never reached the worker at all. See §6.

Items 10 and 11 are new on 2026-07-27, both from codifying the bootstrap path (§3b). Neither
is urgent — 10 is adopting a controller that already works, 11 is testing a rebuild path that
is already better than it was. They are here because both are the kind of work that only ever
gets done deliberately.

Item 12 was opened and closed on 2026-09-03. `dash.henrydowd.dev` was gated at `one_factor`,
but the same pod also answered on `home.dowd.ie` — a second apex outside the `henrydowd.dev`
session cookie, public and ungated — so the link grid stayed world-readable and no keyed
widget could be added. Resolved by dropping the host from Traefik rather than paying for a
second Authelia cookie domain (ADR 018). `dash.henrydowd.dev` and `dash.lan` are now the only
names on that pod, and phase 9's step 4 is unblocked.

Two loose ends outside this repo: the cloudflared route and the Technitium record for
`home.dowd.ie` still exist, so the name resolves and Traefik answers 404. Harmless, and worth
tidying when you are next in those consoles.

### Already done (2026-07-25 / 26 / 27)

Disk reservation on `/mnt/longhorn` dropped 30% → 10% and the existing disk's
`storageReserved` patched to match, returning the disk to `Schedulable: True` and
re-enabling auto-salvage. Verified 2026-07-27; detail in §1.

All 11 volumes salvaged and verified (clean mounts, no journal replay, clean postgres WAL
redo, backups re-run successfully). `LonghornDiskUnschedulable` and
`LonghornProvisioningHeadroomLow` alerts committed and live. Worker OS disk 84% → 82%,
journald capped. `ansible/` created. Incident written up in
`docs/lessons/storage/longhorn-autosalvage-blocked-diskpressure.md`.

---

## 1. Longhorn auto-salvage was disabled by disk over-provisioning

**Resolved on the live cluster 2026-07-27. Not yet durable across a rebuild — read the
last section before treating a green alert as safety.**

The worker's data disk sat at `Schedulable: False` / `DiskPressure`, and Longhorn's
auto-salvage skips replicas on an unschedulable disk, so any event that faulted the volumes
needed manual recovery instead of self-healing. That is what turned a routine reboot into a
16-hour outage on 2026-07-25.

Two compounding causes: `storage-reserved-percentage-for-default-disk=30` applied 147 GiB of
reservation to a *dedicated* data disk that needs none, and Longhorn schedules on
provisioned size, so `immich-library` counted 200 GiB while holding 44 GiB. That put
351.0 GiB of scheduled replicas against a 343.8 GiB limit — over by ~7.2 GiB.

**What was done (2026-07-27).** The setting was patched to `10`, and because the setting
does not retroactively touch a disk that already exists, `storageReserved` on
`default-disk-25a91b93472172c4` was patched from 158188673433 to 52729557811. Both commands
are in `docs/runbooks/cluster-rebuild.md` §3.

**Revised 2026-08-10 (10% → 16%).** `vdb` stopped being a dedicated Longhorn disk when
containerd and the local-path PVs moved onto it (§3). The reserve is what keeps Longhorn
from scheduling into space that data needs, so it was raised to 80 GiB: ~30 GiB of foreign
data today, ~60 GiB if containerd and the local-path claims both grow out.

100 GiB was tried first and rejected. It works, but it lands at 0.8975 on the
`LonghornProvisioningHeadroomLow` ratio, a quarter of a percent under the warning
threshold — one new PVC from a false alarm. The ceiling proper is ~140 GiB, where
`ProvisionedLimit` drops below `ScheduledTotal` and this whole item comes back. Err low:
under-reserving costs nothing while `vdb` has 333 GiB actually free, and over-reserving is
the failure that has already happened once.

Verified after the change:

```text
setting storage-reserved-percentage-for-default-disk   16
/mnt/longhorn  storageReserved   80.0 GiB   (was 147.3, then 49.1)
Schedulable    True                         (was False / DiskPressure)
ScheduledTotal    351.0 GiB
ProvisionedLimit  411.1 GiB   (100% of 491.1 GiB max − 80.0 GiB reserved)
```

60.1 GiB of headroom, 85% of the limit consumed. All 11 volumes `attached` / `healthy`.
`longhorn_disk_status{condition="schedulable"}` is 1 on both nodes, and neither
`LonghornDiskUnschedulable` nor `LonghornProvisioningHeadroomLow` is firing.

**Detection is in place** (`k8s/apps/monitoring/homelab-rules.yaml`, auto-synced):
`LonghornDiskUnschedulable` fires critical on
`longhorn_disk_status{condition="schedulable"} == 0`, and `LonghornProvisioningHeadroomLow`
warns at 90% of the provisioning limit so a recurrence is caught *before* it disables
salvage. Both verified against live series. Expressed as a ratio rather than absolute bytes,
because an absolute threshold false-positives on the control node. Re-check headroom after
adding any large PVC — it is provisioned size that counts, and right-sizing
`immich-library` is still the other half of the margin.

**The distinction that matters: a green alert describes the running cluster, not the repo.**
There are three separate layers here, and fixing one does not fix the next:

| Layer | State | Fixed by |
|---|---|---|
| Longhorn *setting* (governs disks created from now on) | 10 ✅ | imperative patch, live only |
| The *existing* disk's `storageReserved` | 49.1 GiB ✅ | separate imperative patch — the setting does not backfill it |
| The declared value a rebuild would inherit | still unadopted ❌ | open action 6 |

`k8s/infrastructure/longhorn.yaml` declares `storageReservedPercentageForDefaultDisk: 10`,
but that Application is deliberately not auto-synced and has never been synced — ArgoCD
still reports it `OutOfSync`. Until it is adopted, both patches above live only in the
running cluster's etcd. A rebuild that skips the runbook comes back at 30%, auto-salvage is
dead from first boot, and `LonghornDiskUnschedulable` stays green through the whole rebuild
until enough PVCs exist to cross the limit — which is exactly when it is least useful. The
alert is a smoke detector for drift, not evidence that the configuration is captured
anywhere. See §3b.

Full detail: `docs/lessons/storage/longhorn-autosalvage-blocked-diskpressure.md`

---

## 2. Critical alerts fire into email and nothing escalates

**Severity: high. Already cost 16 hours.**

Detection is fine. `LonghornVolumeDegraded` fired correctly and on time during the
2026-07-25 outage, confirmed against stored `ALERTS` series. Eleven volumes then sat
faulted overnight because a critical alert at 19:34 on a Saturday reaches an inbox nobody
is reading.

Every incident so far has been found by looking, not by being told.

**Prevention:** route `severity: critical` to something that interrupts (ntfy, Gotify,
Pushover) and leave `warning` on email. This is a routing change in Alertmanager, not a
new rule.

---

## 3. Worker OS disk cannot absorb its own local-path claims

**Resolved 2026-08-10. `/dev/vda2` went 85% → 6% by moving both consumers onto `vdb`.**

`vda2` is 41 GiB and reached 85% for the third time. The first two rounds treated it as a
cleanup problem — grow the disk 32→44 GiB in June, vacuum the journal and prune images in
July — and it crept back both times, because none of the space was reclaimable. At 85%
kubelet was logging `FreeDiskSpaceFailed` every 90 seconds and freeing zero bytes, sitting
on the `imagefs.available<15%` eviction threshold at 14.9%.

So the data moved instead of the disk growing again:

| Consumer | Was | Now |
|---|---|---|
| containerd images | 24 GiB on `vda2` | bind-mounted to `/mnt/longhorn/k3s-containerd` |
| local-path PVs | 6.1 GiB on `vda2` | re-provisioned under `/mnt/longhorn/local-path` |
| journal | 203 MiB | unchanged, still capped at 200M |

```text
/dev/vda2   41G  2.3G   37G   6%   /          (was 33G used, 85%)
/dev/vdb   492G  134G  333G  29%   /mnt/longhorn
nodefs  avail 89.6%   imagefs avail 67.7%     (eviction at <15%)
```

Both halves are in `ansible/roles/data_disk` and `k3s_local_storage_path`, so a rebuild
gets this without anyone remembering. The role prepares but never performs the cutover —
copying containerd means stopping `k3s-agent`, which detaches every Longhorn volume.

**Three things worth keeping, because they are the parts that bite:**

1. **`local-path-config` is not the knob.** The ConfigMap in `kube-system` is owned by k3s
   (`objectset.rio.cattle.io` annotations) and re-applied from
   `/var/lib/rancher/k3s/server/manifests/` on every restart, so editing it is reverted.
   The durable setting is the k3s **server** flag `--default-local-storage-path` in
   `/etc/rancher/k3s/config.yaml`. Being a server flag makes it cluster-wide: control has no
   `vdb`, so a local-path PVC landing there would create that path on its own OS disk.
   None do today and control has 20 GiB free, but that is why it is one value and not a
   per-node map.

2. **A PV's path cannot be edited.** `spec.persistentVolumeSource` is immutable, and
   deleting the PV alone just parks it in `Terminating` behind the `pv-protection`
   finalizer while it stays bound. Moving an existing local-path volume means: set the PV
   to `Retain`, stop the consumer, delete the PVC, let the PVC be recreated (it provisions
   a fresh PV at the new path under a *new* UID directory), then copy the old data into
   that new directory. The flag alone only redirects *new* volumes.

3. **Stopping the consumer means suspending GitOps at the root.** `selfHeal` reverted a
   `scale --replicas=0` within 3 seconds, and patching the app's own `syncPolicy` was
   itself reverted by `root-app` seconds later — app-of-apps means suspending the child is
   not enough. `vmsingle` additionally needs `spec.paused: true` on the VMSingle CR,
   because the operator (not ArgoCD) owns its Deployment. Save every `syncPolicy` before
   touching it and diff them back afterwards.

`DiskFillingUp` already fires on this and did during the incident, so the warning path works.

**What is left.** `vdb` is now a shared disk rather than a dedicated Longhorn one, which is
the coupling this item previously warned about: containerd growth reduces Longhorn's free
space. It is accounted for — `storageReserved` was raised 49.1 → 80 GiB (§1) — but the two
are linked now, so re-check headroom after anything that grows the image set. A separate
`vdc` is still the clean separation if Proxmox access is convenient.

---

## 3b. Config that no GitOps mechanism reapplies

**Severity: medium. The failure mode is a rebuild that silently comes back wrong.**

ArgoCD covers `k8s/`. Three classes of configuration sit outside it, in descending order of
how well they are protected:

| Layer | Current mechanism | Survives |
|---|---|---|
| App manifests, alert rules, StorageClasses for apps | ArgoCD, self-healing | everything |
| ArgoCD itself, Sealed Secrets controller, repo creds, `argocd-cm` | `bootstrap/bootstrap.sh`, pinned | a scripted rebuild — but the script has never been run end-to-end |
| Longhorn settings, replica count, disk reservation | imperative patches in `cluster-rebuild.md` §3 | a documented rebuild, if someone follows it |
| k3s server flags | `ansible/roles/k3s_node` → `/etc/rancher/k3s/config.yaml` | a k3s reinstall (the installer does not overwrite it) |
| Worker OS config (journald cap, iSCSI ordering) | `ansible/roles/{common,longhorn_node}` | an Ansible run — applied 2026-07-27, but nothing runs it on a schedule |

The Longhorn row has already failed once in a way that matters. `numberOfReplicas` silently
stayed at 3 for months because the StorageClass knob was missed, and every volume sat
degraded with replicas on the control node's OS disk. Documentation is not self-healing.

**Prevention:**

1. **Longhorn as an ArgoCD Application — written, not yet adopted.**
   `k8s/infrastructure/longhorn.yaml` now exists, pinned to chart 1.11.2 and matching the
   `victoria-metrics.yaml` pattern. It declares everything currently patched by hand:
   `defaultReplicaCount`, `storageReservedPercentageForDefaultDisk`,
   `storageOverProvisioningPercentage`, and `persistence.defaultClassReplicaCount` (the
   StorageClass knob that drifted). As of 2026-07-27 it also holds the only declared copy of
   the §1 fix, so until it is synced that fix exists solely as live etcd state.

   **It carries no `syncPolicy.automated`, on purpose.** Every other app in
   `k8s/infrastructure/` self-heals; this one must not, because the parent `infrastructure`
   app auto-syncs and would otherwise Helm-apply over a live Longhorn holding 11 volumes.
   The Application object gets created on commit; nothing reaches the cluster until someone
   syncs deliberately. Do not "Sync All" while it shows OutOfSync.

   Adoption is a maintenance-window job: verify volumes healthy, diff, sync, re-check the
   disk `Schedulable` condition, then delete the now-stale imperative patches from
   `cluster-rebuild.md` §3. Verify the chart's value key names first — Longhorn has renamed
   `defaultSettings` keys across minor releases.

   A useful side effect while it sits unsynced: the diff is a live inventory of how far the
   hand-install has drifted from the declared state.
2. **Move k3s server flags into `/etc/rancher/k3s/config.yaml`.** k3s reads it on every
   start and the installer does not overwrite it, so flags survive a reinstall. Today they
   exist only in the systemd unit that the original curl command generated.
3. **Worker OS config now has an owner: `ansible/`.** Three narrow roles cover the journald
   cap, `/etc/rancher/k3s/config.yaml`, and the `k3s-agent`↔iSCSI shutdown ordering. Run
   `ansible-playbook -i inventory.ini site.yml --check --diff` before applying.

   **Applied to both nodes 2026-07-27**, and re-running it now reports `changed=0` on each,
   so the three roles are exercised and idempotent rather than merely validated YAML. The
   first run surfaced three defects that only an execution could have found: the
   `stdout_callback = yaml` in `ansible.cfg` had been removed from ansible-core and failed
   every run before a task ran; the journald drift assert fired under `--check` against
   state the same run was about to write, and with `serial: 1` that aborted the play before
   the worker was ever reached; and the worker was carrying the journald cap twice. All
   three are fixed.

   One caveat remains: it is pull-on-demand, so nothing runs it on a schedule and drift
   between runs is invisible. That is acceptable at two nodes; it stops being acceptable if
   a third appears. §6 is the argument for closing it sooner.

   Proxmox VM definitions remain out of scope, with the reasoning in `ansible/README.md`.
4. **The bootstrap layer now has an owner: `bootstrap/`.** Sealed Secrets, ArgoCD, the
   `argocd-cm` exclusions patch, the repo credentials and `root-app` were a sequence of
   commands to copy out of `cluster-rebuild.md` §4–6. They are now
   `bootstrap/bootstrap.sh`, with versions pinned in `versions.env` and the ConfigMap patch
   as a reviewable file rather than an `\n`-escaped string inside a `kubectl patch`. The
   decision, and the Ansible/Terraform alternatives rejected, are in ADR 017.

   Writing it found that **the runbook did not describe this cluster**. Three mismatches,
   all caught by diffing against live state rather than by reading:

   | Documented | Actual | Consequence of following the runbook |
   |---|---|---|
   | Sealed Secrets via upstream raw manifest | Helm release, chart 2.18.6 | a differently-shaped install than the one being replaced |
   | MetalLB via `metallb-native.yaml` from `main` | Helm chart via ArgoCD, pinned 0.14.9 | two MetalLBs in one namespace for ArgoCD to fight with |
   | `argocd-cm` patch with 5 exclusion entries | ArgoCD 3.x stock list has 7 | silently reverts the Cilium and Kyverno exclusions |

   None had caused an outage, because none had been exercised. The MetalLB step is now
   deleted outright — ArgoCD owns it end to end — and the patch is copied verbatim from the
   running cluster.

   **The script has not been run end-to-end.** It is syntax-checked, and its two riskiest
   `kubectl` invocations were dry-run against the live cluster (the `argocd-cm` patch is a
   no-op there, which is the correct result). But the only honest test is a real rebuild
   against a bare cluster — open action 11. Treat it as better-documented, not proven.
5. **Sealed Secrets had no declarative source at all**, discovered 2026-07-27 while writing
   the above. It was not in `k8s/`, not in `ansible/`, and the runbook described installing
   it a different way than it exists. It was simply a Helm release somebody ran once in May.
   Every SealedSecret in this repo depends on that controller, which made it the least
   documented and most load-bearing thing in the cluster.

   `k8s/infrastructure/sealed-secrets.yaml` now declares it, pinned to the running chart
   version and following the `longhorn.yaml` pattern: **no `syncPolicy.automated`**, so
   committing it creates the Application object and nothing more. Adoption is open action
   10. The hazard there is specific — the controller's private key is the trust root for
   every secret in the repo — so `prune` must never be enabled on it, and
   `kubeseal --fetch-cert` should be diffed against the backup before syncing.

   **Committing it immediately found something worse.** ArgoCD could not render the
   Application: `https://bitnami-labs.github.io/sealed-secrets`, the chart repo the live
   controller was installed from in May, now returns a bare 404. The project moved from the
   `bitnami-labs` org to `bitnami` on 2026-06-15, and GitHub Pages does not redirect across
   an org move the way git and browser links do. The correct URL is
   `https://bitnami.github.io/sealed-secrets`, which still carries 2.18.6 / app 0.37.0 —
   an exact match for what is running. Both `k8s/infrastructure/sealed-secrets.yaml` and
   `bootstrap/versions.env` now point there.

   The general lesson is the one to keep: **pinning a version does not protect you if the
   host disappears.** Every chart in `k8s/infrastructure/` is pinned by version, which
   guards against surprise upgrades but says nothing about whether the repo still exists.
   A rebuild is exactly when that bites, because it is the only time all of them are
   fetched at once, and it is the worst time to discover it. Nothing currently checks
   reachability — the running cluster does not care, because the charts were fetched
   months ago.

   Worth a periodic `helm repo update` against every `repoURL` in `k8s/`, as a cheap smoke
   test for the rebuild path. Not yet an open action; noting it here first.

## 4. Worker memory limits are 191% of allocatable

**Severity: medium. Silent until several workloads peak together.**

```text
k3s-worker1   memory requests 5979Mi (50%)   limits 22820Mi (191%)
```

Requests are comfortable, so scheduling is honest. Limits are not: if enough workloads
approach their ceilings at once, the node has no way to satisfy them and the kernel starts
killing. `KubeMemoryOvercommit` and `KubeCPUOvercommit` have both been firing since
2026-07-25 20:27.

Immich alone holds a 3Gi limit and has already been OOMKilled once at 2Gi, so the limits
are not obviously wrong individually. The sum is the problem.

**Prevention:** this is a capacity decision, not a bug. Either accept it explicitly (single
worker, workloads rarely peak together, ~4.5 GiB currently available) or bring the sum
under 100% by trimming the largest limits. Worth recording which, so the alert stops being
ambient noise. `docs/reference/capacity-headroom.md` has the sizing context.

---

## 5. Every Longhorn volume depends on one node

**Severity: medium by design, and the design is deliberate.**

All 11 volumes are `numberOfReplicas: 1` on `k3s-worker1`. Redundancy lives at the ZFS
layer instead (ADR 012). The monitoring stack that would report a failure also runs on that
worker.

This is a considered trade, not an oversight, but it sets the blast radius for everything
above: one node event takes out all storage, and the observer with it.

**Prevention:** none proposed. Recorded so the consequence is explicit when the next
single-node event happens.

---

## 6. Shutdown ordering tears iSCSI out from under live volumes

**Resolved on the live cluster 2026-07-27.** Severity was medium; this is the event class
§1's auto-salvage exists to absorb.

A hypervisor-initiated shutdown stopped `open-iscsi` while containerd was still working
through its stop timeout, dropping 12 iSCSI sessions under mounted, actively-written
volumes. The kernel logged `potential data loss!` on every device. The replicas survived
intact this time. That was luck, not design.

**The fix existed in the repo for two days without existing on the node.** `ansible/` was
written on 2026-07-25 with `roles/longhorn_node` carrying exactly the right drop-in, the
runbook documented the commands, and this file listed the ordering under "worker OS config"
as though `ansible/` owning it meant the worker had it. It did not. Running the playbook for
the first time on 2026-07-27 found the worker still in stock configuration:

```text
After=systemd-journald.socket basic.target sysinit.target network-online.target system.slice
TimeoutStopUSec=1min 30s
```

No `open-iscsi` ordering at all, and the systemd default stop timeout — the precise state
that faulted all 11 volumes on 2026-07-25. Any reboot in those two days would have
reproduced the outage, with §1's auto-salvage the only thing standing behind it.

After the run:

```text
Wants=network-online.target open-iscsi.service iscsid.service
After=sysinit.target network-online.target open-iscsi.service basic.target system.slice iscsid.service
TimeoutStopUSec=5min
```

`daemon-reload` only; `k3s-agent` was not restarted and no volume detached. All 11 volumes
stayed `attached` / `healthy` throughout.

**The lesson is about the gap, not the setting.** A written role, a documented runbook step
and a risk register that mentions all three are not evidence that anything reached the
machine — and the register in this case actively implied that it had. Nothing in the repo
compares declared node state against live node state, so the only thing that closes that gap
today is somebody choosing to run the playbook. That is the case for the scheduled
`--check` run in §3b, and it is stronger than "drift between runs is invisible" made it
sound: the drift here was total, and it sat behind confident documentation.

**Still outstanding:** drain the node before `qm shutdown` rather than issuing it cold. That
is an operator habit, not a config, and nothing enforces it.

---

## 7. Longhorn volumes hold ~40 GiB of untrimmed blocks

**Severity: low. Hygiene, not a threat.**

Longhorn `actualSize` runs well ahead of real filesystem usage, and only three snapshots
exist, so this is unreclaimed blocks rather than snapshot retention:

| Volume | Filesystem used | Longhorn actual | Gap |
|---|---|---|---|
| nextcloud-data | 25 GiB | 42 GiB | 17 GiB |
| immich-library | 25 GiB | 44 GiB | 19 GiB |
| act-runner-data | 84 KiB | 4.99 GiB | ~5 GiB |

The only recurring job configured is `daily-snapshot` (retain 7). There is no `trim` job.

This does not affect scheduling, which uses provisioned size, and `/mnt/longhorn` has
363 GiB free. It does inflate rebuild and backup work.

**Prevention:** add a `trim` recurring job alongside the snapshot job.

---

## 8. Restore has been tested once

**Severity: low probability, total consequence.**

Backups are in good shape. restic to Backblaze B2, daily, `nextcloud` / `gitea` / `immich` /
`paperless`, all reporting success, and verified working against the salvaged volumes on
2026-07-26. Longhorn's own backup target is separately unconfigured (`backuptargets/default`
empty, `available: false`), which is fine given restic covers the data.

**Correction (2026-07-26).** The "102 snapshots in the nextcloud repo" cited here as evidence
of health was the opposite: retention had never pruned anything, because `restic forget`
groups by `host,paths` by default and the hostname is the per-run pod name. Fixed in
`c1b81b3`; see `docs/lessons/backup/restic-retention-never-pruned.md`. The reading error is
worth keeping visible, a large snapshot count says a repo is growing, not that it is well
kept, and this review took it for the latter.

The gap is exercise, not coverage. The last recorded test-restore was 2026-06-12.

**Prevention:** keep the quarterly test-restore cadence. A backup verified only by its own
exit code is a backup with one untested dependency, and the retention bug above is exactly
that failure mode, a job that succeeded nightly at doing nothing.

---

## Cleared during this review

- `journald` had no cap and defaults to 10% of the filesystem (~4 GiB). Now capped at 200M
  in `/etc/systemd/journald.conf`.
- 70 exited containers and 4 orphaned images removed; apt cache cleared. Root went 84% to 82%.
- Certificates all valid, earliest expiry 2026-09-10 (`henrydowd-dev`), cert-manager renewing.
- Control node has room: 29% disk, 2.2 GiB memory available.
