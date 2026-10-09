#!/bin/sh
# Reports VPN health to the healthchecks.io check "homelab-vpn". Installed by
# hand in the WireGuard LXC (101); this file is the source. Runs from root's
# crontab every 5 minutes, one minute after cloudflare-ddns.sh.
#
# Pings success when:
#   - wg0 is up and listening
#   - home.henrydowd.dev resolves in public DNS to the current WAN IP
# Otherwise pings /fail with the reason. If no ping arrives (container down,
# crond stopped, WAN down), healthchecks.io reports it after the grace period.
# Not checked: the router's port forward.
#
# The ping URL is in /etc/vpn-healthcheck.url (root, 0600), not in this file:
# anyone with the URL can send pings and hide an outage.
#
# Install from the repo root, with pct exec (never pct enter on this
# container, see docs/lessons/infra/wireguard-lxc-dstate-freeze.md):
#   ssh pve 'pct exec 101 -- sh -c "cat > /usr/local/bin/vpn-healthcheck.sh"' < lxc/wireguard/vpn-healthcheck.sh
#   ssh pve 'pct exec 101 -- chmod 755 /usr/local/bin/vpn-healthcheck.sh'
#   ssh pve "pct exec 101 -- sh -c 'umask 077; printf %s <ping URL> > /etc/vpn-healthcheck.url'"
# Then add this line to root's crontab (crontab -l > f; append; crontab f):
#   1,6,11,16,21,26,31,36,41,46,51,56 * * * * /usr/local/bin/vpn-healthcheck.sh
URL=$(cat /etc/vpn-healthcheck.url) || exit 1
MISMATCH=/tmp/vpn-healthcheck-mismatch

# The last result and curl's exit code go to /tmp/vpn-healthcheck.last.
ping_hc() {
  curl -fsS -m 10 --retry 3 --data-raw "$2" "$URL$1" >/dev/null
  rc=$?
  echo "$(date -Iseconds) ${1:-ok} $2 (curl exit $rc)" > /tmp/vpn-healthcheck.last
}

port=$(wg show wg0 listen-port 2>/dev/null)
[ -n "$port" ] || { ping_hc /fail "wg0 is not up"; exit 0; }

# If either lookup fails, skip the comparison; that is not a VPN failure. A
# WAN outage also stops the ping, which is reported as down.
wan=$(curl -fsS -m 10 https://api.ipify.org)
dns=$(curl -fsS -m 10 -H 'accept: application/dns-json' \
  'https://cloudflare-dns.com/dns-query?name=home.henrydowd.dev&type=A' |
  sed -n 's/.*"data":"\([0-9.]*\)".*/\1/p' | head -n 1)
if [ -n "$wan" ] && [ -n "$dns" ] && [ "$wan" != "$dns" ]; then
  # A new WAN IP takes one ddns run plus the record's 60s TTL to appear, and
  # the ISP changes it nightly, so a mismatch only counts on two runs in a
  # row.
  if [ -f "$MISMATCH" ]; then
    ping_hc /fail "home.henrydowd.dev resolves to $dns but the WAN IP is $wan"
    exit 0
  fi
  touch "$MISMATCH"
else
  rm -f "$MISMATCH"
fi
ping_hc "" "wg0 listening on $port; home.henrydowd.dev -> ${dns:-?}, WAN ${wan:-?}"
