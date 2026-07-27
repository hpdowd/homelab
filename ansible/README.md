# Ansible: the node layer

ArgoCD owns everything inside the cluster. This owns the two VMs underneath
it — the layer that has, until now, existed only as prose in
`docs/runbooks/cluster-rebuild.md`.

That gap has cost real downtime. The 2026-07-25 outage faulted all 11
Longhorn volumes because `k3s-agent` had no shutdown ordering against
`open-iscsi`, and nothing in the repo could have applied it. A runbook step
is only as good as the person remembering to run it.

## Scope

Deliberately small. This manages node configuration that k3s, ArgoCD and
Helm cannot reach:

| Role | What it owns | Why it can't live in GitOps |
|---|---|---|
| `common` | journald size cap | OS-level; journald predates the cluster |
| `k3s_node` | `/etc/rancher/k3s/config.yaml` | k3s reads it at process start, before any workload exists |
| `longhorn_node` | `k3s-agent` ↔ iSCSI shutdown ordering | systemd unit ordering on the host |

It does **not** manage: Proxmox VM definitions (see Non-goals), k3s
installation itself, or anything inside the cluster.

## Usage

```bash
cd ansible
ansible-playbook -i inventory.ini site.yml --check --diff   # always dry-run first
ansible-playbook -i inventory.ini site.yml
```

Every role is idempotent and safe to re-run. Nothing here restarts k3s or
touches a running volume; the one handler that could disrupt things
(`restart k3s-agent`) is **not** wired up, on purpose — see
`roles/k3s_node/tasks/main.yml`. Changes to k3s flags need a deliberate
restart during a window.

## The first run, 2026-07-27

Applied to both nodes. Re-running now reports `changed=0` on each, so this is
exercised and idempotent, not just validated YAML.

It found one thing that mattered a great deal. **The worker had never received
the iSCSI shutdown ordering** — the fix this repo was created to carry.
`systemctl show k3s-agent -p After` still listed only the stock units and the
stop timeout was still systemd's 90s default, two days after the outage that
the role exists to prevent. The role was right; nothing had ever run it. See
`docs/reference/known-risks.md` §6.

Three smaller defects, all fixed:

- `ansible.cfg` set `stdout_callback = yaml`, which ansible-core has since
  removed (it lives in `community.general`). Every run died before reaching a
  task. Dropped rather than adding a collection dependency for output
  formatting — `--diff` is what actually matters here.
- The journald drift assert in `roles/k3s_node` ran under `--check` against
  state the same run was about to write, so a first dry-run always failed. With
  `serial: 1` that aborted the play on the control node before the worker was
  ever reached. Now skipped when `ansible_check_mode`.
- The worker carried the journald cap twice: the drop-in *and* the hand-added
  block appended to `journald.conf` on 2026-07-26. Both said 200M, so nothing
  was broken, but the next person to raise the cap would have edited one and
  not the other. `roles/common` now removes the legacy block, idempotently.

`config.yaml` was created on both nodes and changes nothing until k3s restarts.
It reproduces the flags the original `curl | sh` baked into the systemd unit
(`--disable traefik`, `--disable servicelb`, `--write-kubeconfig-mode 644` on
the server) and adds an explicit `node-ip` pinning what k3s currently
auto-detects. The worker's join URL and token stay in
`/etc/systemd/system/k3s-agent.service.env`, which is correct — they are
bootstrap credentials, not configuration.

## Non-goals, for now

**Proxmox VM definitions.** Terraform against the Proxmox provider would
cover VM 300/301 (CPU, RAM, disks), and there is a real argument for it —
`vdb` sizing and the RAM floor are both load-bearing and currently
undocumented outside prose. It is not here because the VMs are created once
and edited by hand rarely, so the payback is thin against the risk of a
provider that likes to recreate VMs on innocuous attribute drift. Revisit
if a third node appears.

**k3s installation.** The `curl | sh` line stays in the runbook. Automating
an installer that pins its own version into a systemd unit adds a moving
part without removing one.
