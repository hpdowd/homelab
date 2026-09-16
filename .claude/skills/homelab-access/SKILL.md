---
name: homelab-access
description: How to reach the homelab machines — the `ssh pve` / `ssh k3s-control` / `ssh k3s-worker1` aliases, what runs on each, and the standing rule against `pct enter` into the WireGuard LXC while on the VPN. Use whenever a task needs a shell on the Proxmox host or a k3s node, or any `pct` command against an LXC.
---

# Reaching the homelab

## SSH aliases

Three aliases in `~/.ssh/config`, all `root`, all port 22:

| Alias | Host | What it is |
|---|---|---|
| `ssh pve` | 192.168.1.2 | Proxmox VE hypervisor. Web UI on `:8006`. |
| `ssh k3s-control` | 192.168.1.10 | k3s control-plane VM (Proxmox VM 300). |
| `ssh k3s-worker1` | 192.168.1.11 | k3s worker VM (Proxmox VM 301) — every app workload runs here. |

Always use the alias. Direct `ssh root@192.168.1.2` fails with `publickey` —
the aliases carry the right keys (`id_ed25519_pve` / `id_ed25519_k3s`).

All three are already allowlisted in `.claude/settings.local.json`, so
`ssh pve …`, `ssh k3s-control …` and `ssh k3s-worker1 …` run without a prompt.

`kubectl` runs from the laptop against the cluster directly; SSH into a node
only when the thing you need is not visible through the API (containerd, disk,
`/mnt/longhorn`, journal).

## Proxmox guests

```
LXC 100  Technitium  LAN DNS          192.168.1.5
LXC 101  WireGuard   VPN + ddns       192.168.1.3   <-- see the rule below
LXC 102  AMP         game server      192.168.1.15
LXC 104  (ex-Nextcloud, migrated into the cluster)
VM  300  k3s-control                  192.168.1.10
VM  301  k3s-worker1                  192.168.1.11
```

## Hard rule: never `pct enter` the WireGuard LXC over the VPN

**When connected to the homelab over WireGuard, do not `pct enter` (or
`pct console`) the VPN container from `ssh pve`. Do not SSH into it through the
tunnel either.**

Entering that container's network namespace while the tunnel is up wedges it in
uninterruptible D-state. `kill -9` does nothing, container stop/restart does
nothing, and the only recovery is a **full Proxmox host hard-reboot** — which
takes the whole homelab down with it. It has happened once already:
`docs/lessons/infra/wireguard-lxc-dstate-freeze.md`.

Which container: **the WireGuard one is LXC 101 today.** It was numbered **102**
at the time of the incident and was renumbered during a Proxmox inventory
re-shuffle, so both numbers are in circulation and Henry's standing instruction
names 102. Treat **both 101 and 102 as off-limits to `pct enter` while the VPN
is up** — 101 because it is the real hazard, 102 because the rule was given that
way and the numbering has moved before. Before entering *any* LXC from `ssh pve`
over the VPN, run `pct config <id> | grep -i hostname` and confirm it is not the
WireGuard container.

### Do this instead

- `ssh pve 'pct status 101'` and `ssh pve 'pct exec 101 -- <cmd>'` — both safe
  with the VPN up; neither joins the namespace interactively.
- If a real shell inside it is needed: a LAN session, or the Proxmox web-UI
  console, **with the VPN client disconnected**.

### Also don't diagnose the VPN host from a VPN client

192.168.1.3 is excluded from the tunnel's `AllowedIPs` — it *is* the endpoint —
so pings from a split-tunnel client route out the local Wi-Fi and it reads as
dead while every other 192.168.1.x answers. Same trap on `api.ipify.org`, which
returns your ISP's address rather than home's. Ask from inside the homelab
instead. Full write-up in `docs/reference/gotchas.md`.
