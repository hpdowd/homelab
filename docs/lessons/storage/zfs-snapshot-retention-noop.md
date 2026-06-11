# Incident: ZFS daily snapshot retention never pruned anything

## Date
2026-06-11

## Time lost
~0h — caught during a repo/infra review, not by an outage. Filed because
of what it *almost* was.

## Status
Resolved

## Context
- **System / component:** Proxmox host, `/etc/cron.d/zfs-snapshots`
- **Scope:** every dataset under `tank`
- **State before:** the nightly 02:00 cron had been "running" since it
  was set up. Snapshots were being created fine; retention was assumed
  to be 7 daily per the docs.

## Symptoms
- Every dataset under `tank` held **12** `daily-*` snapshots instead of 7,
  growing by one per day, forever.
- No error ever surfaced — cron output goes nowhere without an MTA, and
  the snapshot half of the `&&` chain succeeded nightly, so the docs'
  "retain 7" claim looked true from a distance.

## Investigation
The old job was a one-liner:

```
0 2 * * * root zfs snapshot -r tank@daily-$(date +\%F) && zfs list -t snapshot -o name | grep 'daily-' | head -n -7 | xargs -r zfs destroy
```

- Counted snapshots per dataset → 12 each, so the prune had never
  worked → confirmed the destroy leg was failing.
- `zfs destroy snap1 snap2` → "too many arguments". `xargs` (without
  `-n1`) passes the whole batch in one invocation, so the destroy failed
  every single night. That's the no-op.

## Root cause
Two independent bugs in the prune leg:

1. **`zfs destroy` accepts one snapshot argument.** `xargs -r zfs destroy`
   hands it dozens, so it exits with a usage error and deletes nothing.
2. **The retention logic was wrong anyway.** `zfs list -t snapshot` sorts
   by name across *all* datasets, so `head -n -7` keeps the last 7 *lines
   of the whole listing* — i.e. 7 snapshots of whichever dataset sorts
   last — and marks every daily on every other dataset for destruction.

Bug 1 masked bug 2. The only reason the pool never lost its snapshot
history to bug 2 is that bug 1 made the whole prune fail first. A
"quick fix" of adding `-n1` without rethinking the selection would have
destroyed all but one dataset's history the next night.

## Fix
Replaced the one-liner with `/usr/local/bin/zfs-daily-snapshot.sh`,
which snapshots once and prunes **per dataset**, newest-first, one
destroy per invocation:

```bash
#!/bin/bash
set -euo pipefail

TODAY="tank@daily-$(date +%F)"
if ! zfs list -t snapshot "$TODAY" >/dev/null 2>&1; then
  zfs snapshot -r "$TODAY"
fi

zfs list -H -o name -r tank | while read -r ds; do
  zfs list -H -t snapshot -o name -S creation -d 1 "$ds" \
    | grep -F "@daily-" \
    | tail -n +8 \
    | xargs -r -n1 zfs destroy
done
```

`/etc/cron.d/zfs-snapshots` now just calls the script.

## Verification
Ran the script by hand, then:

```bash
zfs list -t snapshot -o name | grep daily | sed 's/@.*//' | sort | uniq -c
# → exactly 7 per dataset
```

## Prevention
- The script keeps a header comment pointing back at this lesson so the
  one-liner doesn't quietly come back.
- General rule this reinforces: **a cleanup job that has never been seen
  deleting anything should be assumed broken.** Snapshot counts are a
  one-liner to check; do it whenever touching the host.
- Worth considering later: sanoid, which solves exactly this and adds
  monitoring hooks. Accepted the hand-rolled script for now — one pool,
  one schedule.

## Related
- Operations reference: docs/reference/operations.md (ZFS section)
