# How this repo documents itself

The structure is recorded in the top-level README; each subdirectory README
indexes its own files. This page records the *system*, where a new piece of
knowledge goes and the rules that keep the docs trustworthy.

## Where does this go?

| You have… | It goes in… | Trigger |
|---|---|---|
| a decision with alternatives that were rejected | `adr/` | written when the decision is made (or shortly after, while the rejected options are still remembered) |
| an incident — downtime, data risk, or significant wasted time | `lessons/<domain>/` via `TEMPLATE.md`, **plus** a one-paragraph entry in `reference/gotchas.md` linking to it | after the dust settles, including the dead ends |
| a procedure you'll repeat but not often enough to remember | `runbooks/` | the second time you do it |
| a fact you keep looking up | `reference/` | when you notice the repeat lookup |
| a pointer to upstream (charts, images, docs, release notes) | `reference/resources.md` | when a new component is added |
| a multi-step build that hasn't happened yet | `plans/` | when the work is scoped; a plan that's been executed should say so at the top and point to the ADR/lessons it produced |

If it's none of these, it probably belongs in a manifest comment next to the
thing it describes, constraints live closest to what they constrain (see the
`enableServiceLinks` or AppArmor comments for the style).

## Rules

- **Versions are stated once, in `k8s/` manifests.** Docs never restate a
  version number; they say where to look (`grep -rn targetRevision k8s/`).
  Anything duplicated will drift, and drifted docs are worse than none.
- **The top-level README is a map, not a document.** It orients and links;
  content lives behind the links. It is also the public face of the repo,
  staleness shows there first.
- **`gotchas.md` is the index of sharp edges:** one paragraph each, linked
  to the full lesson. If a gotcha has no lesson behind it, that's allowed;
  a lesson without a gotcha entry is a filing error.
- **Every subdirectory README has a file index table.** Adding a file means
  adding its row; the READMEs are the indexes, there is no other catalog.
- **ADR numbering is permanent.** 001–003 predate the habit and stay
  reserved. Reversed decisions get `Status: Superseded` + a pointer, never
  a rewrite.
- **Commit messages are terse lowercase one-liners:** what changed and the
  load-bearing why, e.g. `traefik: disable 60s readTimeout (v3 default) --
  killed lan uploads >60s`. No prose bodies, no trailers.
- **`HOMELAB.md` is gitignored on purpose.** It's the machine-local context
  file for AI-assisted sessions, kept current, never committed. Nothing in
  the repo may depend on it; anything durable in it that humans need must
  also exist in `docs/`.
- **Public sharing goes through `public-export-checklist.md`:** this is a
  private operational repo; the checklist is the gate, not good intentions.
