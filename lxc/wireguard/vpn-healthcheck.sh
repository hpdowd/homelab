#!/bin/sh
# VPN health ping for healthchecks.io (check "homelab-vpn"). Deployed by hand
# to the WireGuard LXC (101), which no layer in this repo manages; this copy
# is the source. Runs from root's crontab every 5 minutes, a minute after
# cloudflare-ddns.sh, and pings success only if the VPN looks usable from
# outside, as far as that can be told from in here:
#
#   - wg0 is up and listening
#   - home.henrydowd.dev resolves, in public DNS, to the current WAN IP
#
# Otherwise it pings /fail with the reason, which healthchecks.io reports at
# once. No ping at all (container down, crond dead, WAN down) is reported
# after the check's grace. Not covered: the router's port forward, which only
# a client outside the house can prove.
#
# The ping URL lives in /etc/vpn-healthcheck.url (root, 0600), not here:
# whoever holds it can make a dead VPN look alive. See known-risks §9.
#
# Install, from the repo root. Use pct exec, never pct enter, on this
# container: see docs/lessons/infra/wireguard-lxc-dstate-freeze.md.
#   ssh pve 'pct exec 101 -- sh -c "cat > /usr/local/bin/vpn-healthcheck.sh &&
#     chmod 755 /usr/local/bin/vpn-healthcheck.sh"' < lxc/wireguard/vpn-healthcheck.sh
#   ssh pve "pct exec 101 -- sh -c 'umask 077; printf %s <ping URL> > /etc/vpn-healthcheck.url'"
#   then add to root's crontab (crontab -l > f; append; crontab f):
#   1,6,11,16,21,26,31,36,41,46,51,56 * * * * /usr/local/bin/vpn-healthcheck.sh
URL=$(cat /etc/vpn-healthcheck.url) || exit 1
MISMATCH=/tmp/vpn-healthcheck-mismatch

# The last result, and whether the ping itself got through, is kept in
# /tmp/vpn-healthcheck.last for checking from `pct exec`.
ping_hc() {
  curl -fsS -m 10 --retry 3 --data-raw "$2" "$URL$1" >/dev/null
  rc=$?
  echo "$(date -Iseconds) ${1:-ok} $2 (curl exit $rc)" > /tmp/vpn-healthcheck.last
}

port=$(wg show wg0 listen-port 2>/dev/null)
[ -n "$port" ] || { ping_hc /fail "wg0 is not up"; exit 0; }

# Either lookup failing is not the VPN failing, so the comparison is skipped
# then. A WAN outage stops the ping below as well, which reads as down anyway.
wan=$(curl -fsS -m 10 https://api.ipify.org)
dns=$(curl -fsS -m 10 -H 'accept: application/dns-json' \
  'https://cloudflare-dns.com/dns-query?name=home.henrydowd.dev&type=A' |
  sed -n 's/.*"data":"\([0-9.]*\)".*/\1/p' | head -n 1)
if [ -n "$wan" ] && [ -n "$dns" ] && [ "$wan" != "$dns" ]; then
  # A new WAN IP takes one ddns run plus the record's 60s TTL to show up, and
  # the ISP rotates it nightly, so only a mismatch seen on two runs in a row
  # counts.
  if [ -f "$MISMATCH" ]; then
    ping_hc /fail "home.henrydowd.dev resolves to $dns but the WAN IP is $wan"
    exit 0
  fi
  touch "$MISMATCH"
else
  rm -f "$MISMATCH"
fi
ping_hc "" "wg0 listening on $port; home.henrydowd.dev -> ${dns:-?}, WAN ${wan:-?}"
