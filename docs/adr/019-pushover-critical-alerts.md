# ADR 019: Alert delivery: Pushover for criticals, a dead-man's switch, quieter boots

**Status:** Accepted
**Date:** 2026-10-09
**Supersedes:** ADR 005 decision 4 (alerts by email, ntfy later). The rest of
ADR 005 stands.

## Problem

- Criticals only went to email. On 2026-07-25 `LonghornVolumeDegraded` fired
  at 19:34 on a Saturday, nobody read the email, and eleven volumes stayed
  faulted overnight. The outage lasted 16 hours (known-risks §2).
- The alerting stack runs on the worker, so it cannot report the cluster
  being down. During the four power cuts between 2026-09-02 and 10-08 nothing
  reported the outage until the host was back.
- Every boot sends a burst of warnings that clear on their own: 28–45
  `PodCrashLooping` series on each of the six boots between 09-16 and 10-08.

## Decisions

### Criticals go to Pushover as well as email

| Setting | Value | Reason |
|---|---|---|
| Scope | `severity: critical` only | In the 30 days before this change, 2 critical series fired. 207 `PodCrashLooping` warning series fired, all on reboot days |
| Routing | Separate `pushover` route with `continue: true`, before the email critical route | Email still gets every critical. Each route has its own notification pipeline and repeat interval |
| Priority | `0` firing, `-1` resolved | `0` follows the app's quiet hours, so a critical at night waits until morning. The upstream default, `2`, repeats until acknowledged |
| Repeat | 4h (email stays 1h) | Long-running criticals such as `BackupJobMissing` don't need an hourly push |
| Message | One line per alert, from `summary` | The default concatenates every annotation |
| Link | `https://grafana.henrydowd.dev` | The default links to Alertmanager's in-cluster address. Grafana works on the LAN and over the VPN |
| Credentials | SealedSecret `alertmanager-pushover` (`user_key`, `token`) | Same pattern as `alertmanager-smtp`. The token belongs to a dedicated Pushover application and can be revoked on its own |

### Warnings are suppressed for 30 minutes after a boot

- `NodeRecentlyBooted` (`homelab-rules.yaml`) fires while the most recently
  booted k3s node has been up for less than 30 minutes. It is null-routed. An
  inhibit rule suppresses `severity: warning` while it fires.
- Across the six boots, `PodCrashLooping` first fired 7–10 minutes after
  boot, each series lasted about 10 minutes, and the last cleared by 23
  minutes. A 5-minute silence after power-up would have ended before the first
  one fired.
- Warnings still firing when the window ends are sent then. Warnings that
  clear inside the window are never sent.
- Not suppressed: `ProxmoxHostRestarted`, `NodeRebooted` and all criticals.
- If node-exporter data is missing the rule does not fire, so nothing is
  suppressed.

### nextcloud-cron alerts on staleness, not on single failures

- The cron runs every 5 minutes. The run that starts during boot fails
  because Postgres is not up yet, and the failed Job is kept for 24 hours, so
  `KubeJobFailed` emailed every 6 hours for a day after each boot. It was the
  only failed Job after any of the six boots.
- `KubeJobFailed` is null-routed for `nextcloud-cron-*` only.
  `NextcloudCronStale` fires when there has been no successful run for an
  hour, or kube-state-metrics has no record of one. Other Jobs, backups
  included, still alert on any failure.

### A dead-man's switch at healthchecks.io

| Setting | Value | Reason |
|---|---|---|
| Route | `Watchdog` → webhook receiver `deadman`, first route; `group_wait: 0s`, `group_interval: 1m`, `repeat_interval: 50s` | Pings about once a minute: a repeat interval below the group interval re-sends on every flush. Alertmanager logs a warning about this on each reload; it is expected |
| `send_resolved` | `false` | If vmalert stops, `Watchdog` resolves, and sending the resolve would count as a ping |
| Check | `homelab-alertmanager`, period 1 min, grace 10 min | Reports down about 11 minutes after the last ping. A clean worker reboot takes about a minute plus pod start |
| Notifications | healthchecks.io's Pushover integration (Normal for down, Low for up) and its email | Sent by healthchecks.io, so they don't depend on the homelab or on Brevo |
| Credentials | SealedSecret `alertmanager-healthchecks` (`ping_url`), read with `url_file` | Anyone with the URL can send pings and hide an outage |

It covers a power cut, the host or worker going down, the WAN going down, and
vmalert or Alertmanager failing. It does not cover failing scrapes, because
`Watchdog` needs no data. The `*MetricsAbsent` rules cover those.

A second check, `homelab-vpn`, watches the WireGuard LXC:
`lxc/wireguard/vpn-healthcheck.sh` runs every 5 minutes (period 5 min, grace
10 min). See `reference/services.md` and known-risks §9.

## Rejected

- **Self-hosted ntfy or Gotify:** it would run on the cluster and fail in the
  same outages it should report. It would also have to be reachable from the
  phone outside the LAN.
- **ntfy.sh (hosted):** on the free tier the topic name is the only access
  control, and Alertmanager has no ntfy receiver, so it would need a webhook
  bridge.
- **Telegram or Discord:** alerts would be mixed in with personal messages.
- **Pushover's email gateway (`@pomail.net`):** it uses the same Brevo SMTP key
  as alert email, so one bad credential stops both, and its priority is fixed
  per address.
- **Emergency priority (`2`):** repeats until acknowledged; not wanted at
  night.

## Consequences

- Labelling a rule `severity: critical` means it reaches the phone. The
  chart's critical rules are included; none fired in the 30 days before this
  change.
- If Pushover fails, `AlertmanagerFailedToSendAlerts` (a warning) arrives by
  email.
- Pushover and healthchecks.io are external dependencies, which is why they
  can report an outage of the homelab.
- A real warning that starts just after a boot arrives up to 30 minutes late.
- A planned host reboot longer than the grace period causes a "down"
  notification.
- `Watchdog` must never reach email or Pushover. If it does, the routing is
  broken (see the null-route-typo lesson).

## Verification (2026-10-09)

- Synthetic critical (`amtool alert add`): delivered to the phone and to
  email; the resolve was sent at priority `-1`. Synthetic warning: email only.
- Boot suppression: with a fake `NodeRecentlyBooted` active, a test warning was
  suppressed and a fake `NodeRebooted` was not. The test warning was emailed
  after the fake ended.
- `NextcloudCronStale`: evaluated against the 10-07 boot (stale for about 5
  minutes, then fresh) and with a non-existent CronJob name, which makes the
  `absent()` branch fire.
- Dead-man: `Watchdog` silenced for 20 minutes. Last ping 00:22:06Z, "down"
  email 00:33Z, pings resumed 00:43Z, then the "up" email. Pushover was
  connected on the healthchecks.io side after this test.
- VPN check: each failure case dry-run in the container; the first scheduled
  run at 01:01Z was delivered.
