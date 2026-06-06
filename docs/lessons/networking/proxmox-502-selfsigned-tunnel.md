# Incident: Proxmox 502 over Cloudflare tunnel — self-signed cert on :8006

## Date
2026-05-27

## Time lost
~Short.

## Status
Resolved.

## Context
- **System / component:** `proxmox.henrydowd.dev`, exposed via the Cloudflare tunnel to the Proxmox web UI at `https://192.168.1.2:8006`.
- **Scope:** Proxmox web UI access through the public domain only.
- **State before:** Setting up the tunnel route to the Proxmox UI.

## Symptoms
- `proxmox.henrydowd.dev` returned **502 Bad Gateway** through the tunnel.
- The Proxmox UI itself was reachable directly on the LAN at `https://192.168.1.2:8006`.

## Investigation
- Direct LAN access worked, so Proxmox and the UI were healthy — the failure was in the tunnel → backend hop.
- Proxmox serves its UI over HTTPS with a **self-signed certificate**. The tunnel connector was rejecting the upstream TLS because the cert couldn't be verified.

## Root cause
The Cloudflare tunnel validates upstream TLS certificates. Proxmox's `:8006` endpoint presents a self-signed cert, which fails verification, so the connector refused the backend connection and returned 502.

## Fix
Set `noTLSVerify: true` on the tunnel ingress rule for the Proxmox service so the connector accepts the self-signed upstream cert.

## Verification
`proxmox.henrydowd.dev` loaded the UI through the tunnel after the change.

## Prevention
This is a **repeatable pattern** — any HTTPS backend with a self-signed cert exposed through a proxy needs TLS verification disabled on that upstream hop. In the current k3s setup the equivalent is the Traefik `ServersTransport` with `insecureSkipVerify: true` on the Proxmox `IngressRoute`.

## Related
- Current implementation: `k8s/apps/proxmox/servers-transport.yaml` (`insecureSkipVerify: true`) + `ingress-route.yaml` (`scheme: https`).
- Same root concept, two eras: cloudflared `noTLSVerify` (Caddy/LXC era) → Traefik `ServersTransport` (k3s era).
