# How this thing is put together

A walkthrough of what's actually running and how a request gets from
"someone types nextcloud.henrydowd.dev" to "a pod responds". Written
for me-in-six-months who's forgotten how some of this works.

## The hardware

One Dell Optiplex with an i5-14500T, 24GB of RAM, a 256GB SSD for the
OS, and two 2TB HDDs in a ZFS mirror called `tank`. That's it. The
whole homelab is one box.

Proxmox is on the bare metal. Inside Proxmox there are some LXCs (the
permanent ones — DNS, VPN, AMP) and two full VMs that make up the k3s
cluster. The split matters because LXCs share memory with the host
(they only use what they touch) but VMs *reserve* their RAM the
moment they boot. So the two k3s VMs eat 17GB up front whether
they're idle or hammered.

```
Proxmox host
├── LXC 100  Technitium  (LAN DNS)
├── LXC 101  WireGuard   (VPN + cloudflare-ddns)
├── LXC 102  AMP         (game server)
├── VM  201  QBittorrent (PIA-only torrenting)
├── VM  300  k3s-control   2 vCPU, 3.5GiB RAM
└── VM  301  k3s-worker1   8 vCPU, 14GB RAM, has the 500GB Longhorn disk
```

## The cluster

k3s. Two nodes. Control runs the API server and friends, worker runs
everything else. k3s was installed with `--disable traefik
--disable servicelb` because I wanted to bring my own (MetalLB +
hand-configured Traefik).

What's in the cluster:

- **ArgoCD** — watches this repo and applies what it finds. The only
  thing pointed at it directly is `root-app`; root-app discovers
  every other Application by watching `k8s/apps/` for `<name>.yaml`
  manifests — **non-recursively**, so a bare subdirectory with no
  matching top-level Application is silently ignored (this bit me —
  see `docs/lessons/k8s/grafana-monitoring-sync-cascade.md`). That's
  the "app-of-apps" pattern.
- **Longhorn** — gives me dynamic block storage. Pods ask for a PVC
  and Longhorn carves it out of the worker's 500GB disk. Replica
  count is 1 because there's only one worker; if I ever add a second,
  bump it.
- **Sealed Secrets** — the trick that lets me commit secrets to git.
  I encrypt a `Secret` against the in-cluster controller's public key
  with `kubeseal`, the result is a `SealedSecret`, and the controller
  decrypts it back to a real `Secret` only inside the cluster. The
  controller's private key is the entire trust root — backed up to
  disk and my password manager. Lose it and every sealed secret
  becomes unrecoverable noise.
- **MetalLB** — does the job that a cloud load balancer would do.
  Without it, a `type: LoadBalancer` Service has no way to get a real
  LAN IP. MetalLB has a tiny pool (192.168.1.200–210) and announces
  whatever it hands out over ARP.
- **Traefik** — the ingress controller. Sits on the *one* MetalLB IP
  I actually use (192.168.1.200). Routes by Host header.
- **cloudflared** — runs the public-side tunnel. Cloudflare gives me
  a tunnel ID, that token lives in a SealedSecret, the pod logs into
  Cloudflare with it, and from then on the cloudflared pod is the
  outbound end of a tunnel that Cloudflare uses as the origin for
  `*.henrydowd.dev`. Zero inbound ports open on my router.
- **VictoriaMetrics + Grafana + Alertmanager** — monitoring. Picked
  VM single-node over kube-prometheus-stack because it's ~60% lighter
  on RAM. See ADR 005.

## How a request actually flows

### Someone on the internet hits nextcloud.henrydowd.dev

```
their browser
  → Cloudflare edge (TLS terminates here)
  → my cloudflared pod, over the persistent tunnel
  → Traefik (plain HTTP — TLS is already off)
  → the nextcloud Service
  → a Nextcloud pod
```

The thing to remember about this path: Traefik gets plain HTTP, not
HTTPS, because Cloudflare already handled TLS. The cloudflared
config talks to Traefik's `web` entrypoint. If you create an Ingress
and pin `router.entrypoints: websecure`, it 404s the tunnel because
the router rejects the unencrypted hit. Don't pin entrypoints.

### Someone on the LAN hits nextcloud.lan (or nextcloud.henrydowd.dev)

```
their browser
  → Technitium DNS (LXC 100, .5)
       returns 192.168.1.200 for both .lan and *.henrydowd.dev
  → Traefik on 192.168.1.200
  → the nextcloud Service
  → a Nextcloud pod
```

The `*.henrydowd.dev` LAN trick is split-horizon DNS. Public DNS
resolves it to Cloudflare; LAN DNS (Technitium) returns Traefik
directly. Same hostname, two answers, traffic stays in-house when
you're home. Saves bouncing through Cloudflare for no reason.

### Someone on the LAN hits amp.henrydowd.dev (external backend)

```
browser
  → Technitium → 192.168.1.200 (Traefik)
  → Service amp-external (no selector — selectorless!)
  → EndpointSlice points at 192.168.1.15 (LXC 102 directly)
  → AMP on the LXC
```

This pattern (Service with no selector + hand-written EndpointSlice)
is how I get services that don't live in the cluster to still flow
through Traefik. Traefik doesn't care that the backend is an LXC; as
far as it's concerned it's just an endpoint. Same shape works for
Proxmox (with the wrinkle that the backend wants HTTPS with a
self-signed cert, so it's an IngressRoute + ServersTransport with
`insecureSkipVerify: true`).

## Storage

Two kinds, and the difference matters:

**Longhorn** — replicated block storage inside the cluster. Slower
because of the replication overhead (even at replica=1 there's still
the iSCSI hop). Backed up daily by restic. Most app data goes here.

**local-path** — k3s' default; a `hostPath` on the node. Faster, not
replicated, dies with the node. The VictoriaMetrics TSDB lives here
because monitoring data is regenerable and I don't want 50k samples
per minute hammering Longhorn.

ZFS sits underneath all of this. `tank/wireguard` and a couple of
other LXC subvolumes live on the mirror directly. The k3s worker
also has a 500GB virtual disk that came from a `tank` zvol — that's
where Longhorn's PV data ends up.

## Backups

Two layers, see ADR 004 for the why.

**Local:** Longhorn snapshots daily (retain 7), ZFS snapshots on the
host nightly via cron (retain 7), the Sealed Secrets master key
copied to local disk + password manager.

**Offsite:** restic to Backblaze B2. Per-service repos in one bucket.
Nextcloud backs up live via podAffinity + RO mount; Gitea scales to
0 first because SQLite. `RESTIC_PASSWORD` in the password manager,
not just in the cluster. Restore procedure is in
`docs/runbooks/restore-procedure.md`.

## What's *not* in the cluster

A few things I deliberately keep on LXCs:

- **Technitium** — DNS. The cluster depends on it (LAN names →
  Traefik VIP), so it can't live inside the thing it's serving. Its
  admin UI *is* now reachable through Traefik at `technitium.lan`
  (selectorless Service + EndpointSlice → LXC 100 `:5380`, same
  pattern as AMP), but that's just an ingress shortcut — the DNS
  server itself still runs on the LXC.
- **WireGuard** — the VPN. Also runs cloudflare-ddns, which keeps the
  `home.henrydowd.dev` A record pointed at my current home IP. This
  is how I get back in when I'm out. If the cluster dies, this still
  works.
- **AMP** — game server. Stays on LXC because there's no real upside
  to moving it.
- **QBittorrent** — PIA killswitch via Docker inside a VM. Network
  isolation matters here in a way that's awkward in k3s.

## A note on memory

The thing that constrains every "should I add X" decision is RAM.
After the two k3s VMs reserve theirs, the host has maybe 7GB left for
ZFS ARC, the Proxmox process, and the LXCs that didn't migrate. So
when something says "needs 1.5GB", that's a real percentage of what's
left. It's why I keep picking the lighter option (VictoriaMetrics
single-node, Authelia over Authentik) and why Immich is still on the
bench.
