# Reference

Cheat-sheets for the tools used day-to-day. Not tutorials; just the commands and patterns that come up repeatedly in this specific setup.

| File | Contents |
|---|---|
| architecture.md | How requests flow from browser to pod · storage layers · what lives outside k3s and why |
| services.md | What runs where · hostnames and backends · per-service config facts (images, DBs, secrets, schedules) |
| authelia.md | The SSO stack as deployed — request flow, gated hosts, middlewares, config, secrets, monitoring, operations |
| gotchas.md | The sharp edges — collected one-paragraph warnings with links to the full lessons |
| known-risks.md | Things not yet broken but on a path to breaking — evidence, severity, and the fix for each. Reviewed 2026-07-26 |
| operations.md | ArgoCD · Sealed Secrets · kubectl · Longhorn · ZFS · backup verification · diagnosis flow |
| kubectl.md | Health/status cheat-sheet · 30-second health sweep · pods, events, logs, ingress, storage, rollouts |
| cloudflare-warp.md | WARP CLI setup on Arch/Wayland — backup remote-access path when WireGuard is unavailable |
| capacity-headroom.md | Worker RAM headroom report (the gate for adding services) · how to re-run it from VictoriaMetrics · Collabora/Immich feasibility · re-evaluate triggers |
| resources.md | Where each component's charts, images, docs and release notes live · trust ladder for images · before-an-upgrade checklist |
