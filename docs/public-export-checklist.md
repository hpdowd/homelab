# Public export checklist

Gate for scrubbing this private operational repo before mirroring anything to a
public portfolio. The goal is to demonstrate configs and reasoning without
publishing an internal network map.

## What to strip

### Internal network topology
- [ ] All `192.168.1.x` addresses (replace with `<LAN-IP>` or a clearly fake range like `10.0.0.x`)
- [ ] Proxmox VM/LXC IDs (100, 101, 102, 201, 300, 301…)
- [ ] Physical hardware details that fingerprint the box (exact model, MAC, serial)
- [ ] ZFS dataset paths that reveal directory structure of the host

### Hostnames and domains
- [ ] Internal hostnames (`*.lan`)
- [ ] Real public domain (`henrydowd.dev`) — replace with `<your-domain>` or a placeholder
- [ ] Cloudflare tunnel ID / tunnel name
- [ ] Git repo URL (`git.henrydowd.dev/henry/homelab`)

### Credentials and secrets
- [ ] SealedSecret YAML blobs (they're safe to commit in the private repo but look alarming out of context — annotate or strip)
- [ ] Backblaze B2 bucket name, endpoint URL, and region (`hpd.homelab`, `s3.eu-central-003.backblazeb2.com`)
- [ ] Any `RESTIC_REPOSITORY` values that include the real bucket path
- [ ] Email addresses in Alertmanager config
- [ ] Password manager references that could narrow down what password manager is in use

### Operational state that isn't yours to publish
- [ ] LXC decommission sequences with real IDs
- [ ] `restic check` timestamps that expose backup cadence exactly
- [ ] ZFS snapshot names that embed dates

## What to keep (scrubbed versions are fine)

- All the architecture decisions, ADRs, and lessons — the reasoning is the value
- Kubernetes manifests with real structure, placeholder values substituted
- Runbooks and reference docs with IPs replaced by placeholders
- Phase plan and migration history (the "what" and "why", not the "where")
- Incident post-mortems — these are high-signal portfolio content

## Public repo conventions

- Replace every `192.168.1.x` with the same placeholder (`192.168.1.X`) so a
  reader can follow the topology without knowing the real addresses
- Use `<your-domain>` for `henrydowd.dev` consistently
- Add a `README` note: "IPs and hostnames are placeholders; swap them for your
  own values during bootstrap"
- Do not publish `k8s/` SealedSecret YAML without a note explaining they're
  cluster-specific and useless outside it
