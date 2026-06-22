# ADR 006: Immich, public from day one, raw manifests, backed up like Nextcloud

**Status:** Accepted
**Date:** 2026-06
**Superseded By:** None

## What problem this solves

Photos were the last big thing with no self-hosted home. The plan (phase
6c) parked Immich until the worker's RAM headroom was confirmed; the
capacity report and a 6-day VictoriaMetrics baseline showed the worker
never dropping below ~7.9GiB available, which clears Immich's expected
2.5–3.5GiB steady state with the 2GiB alert cushion intact. The baseline
is shorter than the 2–3 weeks the open-work item wanted, accepted, the
per-node memory alert is the backstop.

## What I picked

1. **Raw manifests, not the Helm chart.** Same reasoning as Nextcloud:
   the repo's app pattern is plain YAML per service, and Immich's chart
   would be one more inline-values surface to drift silently (see the
   ComparisonError lesson). The official `docker-compose.yml` for the
   pinned release is the source of truth for images and env, the
   server, machine-learning, and postgres images are version-paired and
   get bumped together, never separately.

2. **Immich's own postgres image (PG14 + VectorChord), `DB_STORAGE_TYPE:
   HDD`.** Smart search needs the vector extension, and Immich is picky
   about the pairing, the digest comes straight from the release
   compose file. The HDD flag tunes VectorChord for the spinning mirror
   under the vdb.

3. **Public + LAN from day one, before Authelia.** The whole point is
   family members using it from their phones, so LAN-only was never
   going to last. Until phase 8 lands, auth is Immich's own login,
   accepted because Immich's auth is a first-class feature (it's
   designed to face the internet), unlike, say, the ArgoCD UI.

4. **The 100MB tunnel cap is accepted, not solved.** Cloudflare caps
   request bodies at 100MB on the free plan and Immich uploads each
   asset as one request, so large videos fail when uploading through the
   tunnel. Split-horizon DNS already gives the right behaviour at home:
   `immich.henrydowd.dev` resolves to Traefik directly, no tunnel, no
   cap; and home WiFi is where phone backup happens anyway. Remote
   options, in order of preference if it ever actually hurts:
   - WireGuard profile on the phone (already the remote-access story for
     everything else; zero new moving parts)
   - let the mobile app's retry pick large videos up when the phone
     gets home (default behaviour, costs nothing)
   - a DNS-only hostname with a port-forward straight to Traefik
     (rejected for now, reopens the no-exposed-ports posture)

5. **200Gi Longhorn PVC for the library.** Longhorn volumes grow online
   but never shrink, vdb had ~420G free, and photos are the workload the
   500GB disk was sized for. Model cache sits on local-path (regenerable
   downloads, ADR 005 reasoning).

6. **Backed up to B2 from day one, own repo.** Photos are the most
   irreplaceable data in the house; they get the Nextcloud treatment
   (podAffinity + read-only mount + pg_dump, retry loop) in a third repo
   `hpd.homelab/immich` at 04:00, after the other two. `thumbs/` and
   `encoded-video/` are excluded: regenerable derivatives that would
   roughly double the B2 bill. The backup alerts cover the namespace.

## Consequences I should remember

- B2 cost now scales with the photo library (~$6/TB/month). The
  excludes keep it to originals only.
- The ML container is the worker's biggest single tenant (3Gi limit).
  If the first big import OOMKills it, raise the limit, the headroom
  maths is in capacity-headroom.md, and watch `NodeMemoryLowWorker`.
- Immich releases fast and being multiple majors behind makes upgrades
  riskier. Bump deliberately: read the release notes, take the new
  compose file's image trio, change all three in one commit.
- When Authelia lands (phase 8), Immich goes behind it like everything
  else; its mobile app supports OAuth, so that migration is planned,
  not speculative.
