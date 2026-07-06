# ADR 012: Keep the ZFS mirror; don't push redundancy up into Longhorn across two separate disks

**Status:** Accepted
**Date:** 2026-07-06
**Superseded By:** None

## What problem this solves

The idea I talked myself out of: break the 2×2TB ZFS mirror into two independent
single-disk pools, 4TB raw instead of the ~1.8TiB the mirror leaves me, and move
redundancy up a layer. Longhorn `replica=2` with disk anti-affinity for the data
that has to survive a disk dying, `replica=1` for the bulk, regenerable stuff (a
future media library, torrents) that never wanted a second copy in the first
place. The pull of it is selective redundancy; I'd pay the 2× storage cost only
where it earns its keep and get the other half of the spindles back for things I'd
never mirror by choice.

In the abstract it is a good instinct, it is how hyperconverged clusters actually
run, JBOD underneath and the replication done by the storage orchestrator sitting
above it. On this box it is the wrong fit, for a stack of reasons that compound
into one another, and this record exists so I don't sit down and re-derive every
one of them the next time I catch myself eyeing that second 2TB.

## What I picked

Keep the mirror. `tank` stays 2×2TB ZFS RAID-1, Longhorn stays `replica=1` on its
single 500GB zvol, and redundancy stays down at the block layer where it covers the
whole substrate at once rather than only the slice I remember to enrol in it.

## Why moving redundancy into Longhorn loses

Roughly in the order the reasons weighed on me:

- **Blast radius — the mirror protects the things Longhorn structurally cannot.**
  Longhorn only ever replicates volumes that live inside the cluster, and the two
  worst services to lose, Technitium doing LAN DNS and WireGuard doing the VPN, both
  sit on LXCs on purpose; DNS can't live inside the thing it serves, and the VPN is
  the door I come back through when the cluster is face-down. `tank/wireguard`,
  `tank/vmdata`, and the VM root disks are all out there with them. The mirror covers
  the lot today without my having to think about it. Split it into two single-disk
  pools and every one of those lands on one physical disk with no live redundancy at
  all, so a single drive death takes DNS down with it, which cascades straight into
  the cluster because every LAN name resolves through Technitium to the Traefik VIP,
  and it takes my way back in down at the same moment. This moves protection off the
  pieces whose failure hurts most and is slowest to undo, and onto app data that is
  already the best-backed-up thing I own; That is exactly backwards.
- **RAM is the constraint everything else bends around, and `replica=2` spends it.**
  Every "should I add X" call on this host comes down to memory in the end
  (architecture.md, capacity-headroom.md), and a second replica roughly doubles the
  Longhorn engine and instance-manager footprint. I already had to walk control up
  4→5GiB purely to swallow the longhorn-manager heap spike that trips
  `NodeMemoryLowControl` after a worker reboot. Spending the scarcest thing I have to
  buy a weaker copy of redundancy I already get for free runs against the whole grain
  of the design.
- **Spinning rust, and the iSCSI hop sitting on top of it.** Longhorn is already the
  slow path even at one replica, there is still an iSCSI round-trip in the way
  (architecture.md), and `replica=2` puts every write across that hop to both disks
  and then through ZFS on each. On HDDs that is a real, felt tax; the mirror lays
  both copies down far more cheaply and much closer to the metal.
- **I'd be handing back ZFS self-healing.** A mirror scrubs and actually repairs bit
  rot out of the good copy. Single-disk or striped pools still checksum and still
  detect the corruption, but they cannot fix it, there is no second copy at the ZFS
  layer to pull from. Longhorn will rebuild a whole replica when a disk dies, but it
  does not do the quiet block-level scrub-and-repair a mirror does, so this is a
  property I get today for nothing and would simply be giving up.
- **The capacity win is mostly a mirage.** Anything I keep at `replica=2` still costs
  2×, the very thing the mirror was already doing for me; the only real gain sits on
  the `replica=1` bulk, and the thing that frees that space is striping the two disks,
  not Longhorn. So I'd be paying the blast-radius, RAM, spinning-rust, and self-heal
  costs above to buy back capacity that a plain stripe hands me for none of them.
- **And nothing is short on space today anyway.** Longhorn carves 500GB out of a
  ~1.8TiB pool and most of that sits empty. This is a fix for a capacity problem I
  have not actually got yet.

## What would change the answer

- **A third drive.** If the chassis has a bay for one the clean move is the obvious
  one; keep the 2TB mirror for everything that matters and stand a single-disk pool
  up beside it for non-redundant bulk. Full capacity for a media library, none of the
  costs above, nothing destabilised. This is the path I'd take the day capacity
  actually starts to bite.
- **A second node.** Longhorn replication across *nodes* is the right tool the moment
  this stops being a one-box lab, cross-node replicas ride out a whole node dying in a
  way the mirror never can. Same-node disk anti-affinity is a thin imitation of that.
  Revisit it then.
- **Deciding a full restore is an acceptable RTO.** If a rebuild-from-B2 after a disk
  death ever becomes a wait I'm willing to take on the whole box, the honest version
  is a plain 4TB stripe leaning on restic and snapshots, still not the Longhorn
  scheme, which pays 2× on the replicated half and the RAM and perf tax besides. That
  one comes with homework: confirm the DNS and VPN configs are genuinely in the
  offsite set first, because the mirror is the only thing covering them now.

## Related

- ADR 004 — the backup story. The mirror is the live single-disk-failure floor;
  restic→B2 is what catches everything the mirror can't, theft, fire, a fat-fingered
  `zfs destroy`. This decision leans hard on that division of labour.
- `docs/reference/architecture.md` — the storage section (the two-tier
  Longhorn/local-path split and the iSCSI-hop note) and the memory constraint that
  shapes every capacity call.
- `docs/reference/capacity-headroom.md` — the RAM arithmetic each of those calls
  actually runs on.
- HOMELAB.md replica-drift note — Longhorn replica count is two knobs, the setting
  and the StorageClass parameter, and the SC wins; friction the mirror simply doesn't
  carry.
