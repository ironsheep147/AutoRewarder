# One-Time Online Retry Notifier

## Behavior

`autorewarder-online-notifier.sh` runs from cron every 5 minutes.

It sends at most one notification per event:

- AutoRewarder missed its expected 4 AM start.
- Internet went down during the day, then came back.
- Today's log has `AutoRewarder exited with code` nonzero or `ERROR:`.
- Today's log has `===== Started` but no `===== Finished` after `AUTOREWARDER_MAX_RUNTIME_MINUTES`.

It checks today's log, same as:

```bash
tail -n 50 ~/AutoRewarder/logs/autorewarder-$(date +%F).log
```

When internet returns, notification asks whether to run AutoRewarder and includes:

```bash
nohup ~/AutoRewarder/run-random-accounts.sh >/dev/null 2>&1 &
```

No LLM needed. Cron runs Bash only.

## Hermes Telegram notification

Preferred setup: Hermes cron runs this script with `no_agent=True`.

- empty stdout means no Telegram message
- non-empty stdout is delivered to Telegram
- no LLM/model needed

Schedule: every 1 hour.

Keep system cron only for AutoRewarder run:

```cron
0 4 * * * /home/ryan/AutoRewarder/run-random-accounts.sh
```

Optional fallback: set `AUTOREWARDER_NOTIFY_URL` for direct HTTP notification. If unset, script prints alert to stdout for Hermes.

## Manual test

```bash
cd /home/ryan/AutoRewarder
AUTOREWARDER_EXPECTED_HOUR=0 AUTOREWARDER_EXPECTED_MINUTE=0 AUTOREWARDER_START_GRACE_MINUTES=0 ./autorewarder-online-notifier.sh
```

Expected: one notification only.

Check log:

```bash
tail -50 logs/online-notifier-$(date +%F).log
```

## Limit

If internet is down, machine cannot send anything. It records outage and notifies once after internet returns.
