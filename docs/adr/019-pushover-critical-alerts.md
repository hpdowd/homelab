# ADR 019: Pushover for critical alerts, email kept for everything else

**Status:** Accepted
**Date:** 2026-10-09
**Supersedes:** ADR 005, decision 4 only ("alerts go to email for now, ntfy
probably later"). The rest of 005 stands.

## What problem this solves

Critical alerts went to an inbox, and an inbox doesn't interrupt anyone. On
2026-07-25 `LonghornVolumeDegraded` fired on time, and eleven volumes then sat
faulted overnight, because a critical at 19:34 on a Saturday reached an inbox
nobody was reading. That outage cost 16 hours, and detection was never the
problem (known-risks §2).

Email was always meant to be temporary. ADR 005 called the swap "a one-line
change when I get round to it". That stayed true of the config; what kept it
waiting was picking the app.

## Why Pushover, and why not self-hosted

**Self-hosted ntfy or Gotify** was the original plan and is rejected. A
notifier that runs on the cluster goes down with the cluster, and the failure
that has actually been happening here is the whole host going dark: four power
cuts between 2026-09-02 and 10-08 (`docs/lessons/infra/power-cuts-host-stayed-off.md`).
It would also have to be reachable from the phone off the LAN. That means
publishing it through the tunnel with the app's own token auth, since
Authelia's ForwardAuth breaks non-browser clients, or relying on a VPN client
that doesn't autoconnect.

**ntfy.sh, the hosted one**, would avoid that and is free. On the free tier
the topic name is the only secret, though, and Alertmanager (v0.32.1 here) has
no native ntfy receiver, so it needs a webhook template or a bridge in
between.

**Telegram or Discord** both have native receivers, but alerts would land
in the same apps as people, which is the inbox problem again.

**Pushover's email gateway** (an `@pomail.net` address) would have needed no
API token. It is rejected because mail to it goes out through the same Brevo
SMTP key as the alert email, so one broken credential would silence both
channels. Its priority is also fixed per address, so resolves couldn't be
quiet.

**Pushover** costs $5 once for the Android app. Alertmanager has a native
`pushover_configs` receiver that reads its keys from files, like the SMTP
password, and sets the priority per message. The free API allowance per
application is far above what this sends.

## What I picked

| Decision | Choice | Why |
|---|---|---|
| What goes to the phone | `severity: critical` only | 30 days of `ALERTS` before the change: 2 critical series (both `PodOOMKilled`) against 207 `PodCrashLooping` warnings, every one of them on a day the cluster rebooted (09-16, 10-01, 10-07, 10-08). Warnings on the phone would teach me to ignore it |
| Email | Unchanged, and still gets criticals | It is the fallback if Pushover breaks, and Authelia's password-reset mail needs Brevo anyway |
| Routing | A separate Pushover route with `continue: true`, above the email critical route | Two routes means two notification pipelines, so a broken Pushover key can't stop the email, and each can repeat on its own interval |
| Priority | `0` firing, `-1` resolved | Upstream's default is `2` (emergency), which repeats until acknowledged. `0` respects the app's quiet hours, so a critical at night waits for the morning. That is a deliberate choice, not a gap |
| Repeat | 4h on Pushover, 1h on email | A long-running critical such as `BackupJobMissing` after a power cut stays up until I fix it, and the phone doesn't need telling every hour |
| Message | One line per alert, from `summary` | The default joins every annotation together, which is unreadable on a lock screen |
| Link | `https://grafana.henrydowd.dev` | The default points at Alertmanager's in-cluster address, which a phone can't open. Grafana answers on the LAN and over the VPN |
| Credentials | `alertmanager-pushover` SealedSecret (`user_key`, `token`), mounted by `alertmanager.spec.secrets` | Same pattern as `alertmanager-smtp`. The token belongs to a Pushover application made for the homelab, so it can be revoked without touching the account |

## Verified

2026-10-09, with synthetic alerts sent through the live Alertmanager by
`amtool alert add`. A critical routed to `pushover` and `email`, reached the
phone and the inbox, and its resolve went out at `-1`. A warning routed to
`email` alone, and Pushover's send count did not move. No failed
notifications on either integration.

## Consequences

- **`severity: critical` now means "this reaches my phone".** Labelling a
  rule critical is a decision about interruption, not just importance. The
  chart's own critical rules come with it, and none of them has fired in the
  30 days checked.
- **A broken Pushover integration reaches me by email.**
  `AlertmanagerFailedToSendAlerts` is a warning, so it takes the email route.
- **Pushover is a third-party dependency.** Unlike anything on the cluster, it
  keeps working when the cluster doesn't, which is the point.
- **This does not fix the host going dark.** Alertmanager runs on the worker,
  so a power cut still produces nothing until the host is back up. That needs
  a dead-man's switch outside the house: `Watchdog`, the always-firing alert
  that exists for exactly this, is still null-routed.

## Addendum (2026-10-09): warnings are held for 30 minutes after a boot

Every boot brings the same burst of warnings, and every one clears itself.
Over the six boots between 09-16 and 10-08 (three power cuts, the thin-pool
incident and two planned reboots), each produced 28-45 `PodCrashLooping`
series from pods restarting while Longhorn reattached. They first fired 7-10
minutes after boot, each lasted about 10 minutes, and the last was gone by 23
minutes. In email that is one message per namespace and then a resolve for
each, for nothing.

**Decision:** an inhibit rule holds back `severity: warning` while
`NodeRecentlyBooted` fires, which is while the youngest k3s node has been up
under 30 minutes. That rule is null-routed and exists only to feed the
inhibit rule.

- **Why not a silence for 5 minutes after power-up**, which was the first
  idea: the burst starts 7-10 minutes in, because `PodCrashLooping` needs
  `for: 5m` on a 15-minute window, so a 5-minute silence would have expired
  before the first one. A silence also needs something to create it at boot,
  while the inhibit rule is declarative and ends on its own.
- **Held, not dropped.** Alertmanager sends an inhibited alert that is still
  firing once the inhibition ends, so a real crashloop arrives about 30
  minutes after boot instead of never. One that clears inside the window is
  never sent at all, and no resolve is sent for it either.
- **Not held:** `ProxmoxHostRestarted` and `NodeRebooted`, which are the notice
  that a boot happened, and every critical. The one critical seen after a boot
  in the same data, `PodOOMKilled` on cloudflared 5 minutes after the 10-07
  power cut, is a public-ingress OOM worth hearing about.
- **Fails open.** With no node-exporter data the rule has nothing to fire on,
  so nothing is held.
- **`KubeJobFailed` for `nextcloud-cron` needed its own fix.** The run of that
  5-minute cron that fires at boot hangs before Postgres is up and fails, and
  the failed Job is kept for 24 hours (`ttlSecondsAfterFinished`), so the alert
  outlasted any boot window and emailed every 6 hours for a day. It was the
  only `KubeJobFailed` after every boot in the data. It is now null-routed for
  that CronJob alone, and `NextcloudCronStale` alerts on an hour without a
  successful run instead, which is what matters for a cron that runs every 5
  minutes. Other Jobs, the backups included, still alert on any failure.

Verified with synthetic alerts on the live Alertmanager: while a fake
`NodeRecentlyBooted` was active, a test warning was held and a fake
`NodeRebooted` was not, and once the fake ended the held warning was emailed.
`NextcloudCronStale` was checked against the 10-07 boot (5 minutes stale, then
fresh) and with a bogus CronJob name, which makes its `absent()` branch fire.
