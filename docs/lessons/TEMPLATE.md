# Incident: <short title>

## Date
YYYY-MM-DD

## Time lost
~Nh   <!-- optional, but useful: makes prevention work easy to prioritise -->

## Status
Resolved | Ongoing | Mitigated (root cause unconfirmed)

## Context
- **System / component:** which node, VM, LXC, namespace, or service
- **Scope:** what was affected (host-wide? one app? cluster-wide?)
- **State before:** what was happening when it started (a deploy? idle? after a reboot?)

## Symptoms
- What exactly stopped working, from the user's point of view.
- Log excerpts (trim to the smoking gun, don't paste 500 lines):
  ```text
  <the key error line(s)>
  ```
- Frequency: one-off / intermittent / on every <trigger>.

## Investigation
What you actually checked, **including dead ends** — the wrong turns are
often the most useful part for the next person (or future you).
- Hypothesis 1 → ruled out because ...
- Hypothesis 2 → confirmed by ...

## Root cause
The actual mechanism, stated plainly. Not "it was broken" — *why* it broke.

## Fix
```bash
# the commands that actually resolved it
```
If the fix is declarative (a manifest/values change), link the commit or paste
the diff rather than just describing it.

## Verification
How you confirmed it was actually fixed (not just "looks better"):
```bash
# the check that proves it
```

## Prevention
What stops this recurring — a config change, a guard rail, an alert, a runbook,
or "accepted risk, will revisit if it returns".

## Related
- ADR: docs/adr/NNN-...
- Other lessons: docs/lessons/...
- Upstream issue / forum thread: <url>
