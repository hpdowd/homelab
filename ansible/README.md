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

## First run against the existing nodes

The worker already has a journald cap appended directly to
`/etc/systemd/journald.conf` (applied by hand on 2026-07-26). This playbook
uses a drop-in at `/etc/systemd/journald.conf.d/` instead, which wins over
the main file, so the two do not conflict. Remove the hand-added block when
convenient to avoid two sources of truth:

```bash
# on k3s-worker1, delete the trailing [Journal]/SystemMaxUse=200M block
$EDITOR /etc/systemd/journald.conf
```

`--check --diff` on a first run will show `config.yaml` being created on
both nodes. That file does not exist today; k3s flags currently live only
in the systemd unit that the original `curl | sh` generated, which is the
whole problem. Creating it changes nothing until k3s restarts.

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
