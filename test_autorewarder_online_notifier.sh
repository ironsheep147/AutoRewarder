#!/usr/bin/env bash
set -euo pipefail

SCRIPT_PATH="${1:-autorewarder-online-notifier.sh}"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

mkdir -p "$WORK_DIR/bin" "$WORK_DIR/app" "$WORK_DIR/data/state"

cat > "$WORK_DIR/bin/curl" <<'SH'
#!/usr/bin/env bash
set -eu
if [ "${FAKE_CURL_FAIL:-0}" = "1" ]; then
  exit 7
fi
printf '%s\n' "$*" >> "${FAKE_CURL_LOG:?}"
exit 0
SH
chmod +x "$WORK_DIR/bin/curl"

export PATH="$WORK_DIR/bin:$PATH"
export HOME="$WORK_DIR/home"
export AUTOREWARDER_APP_DIR="$WORK_DIR/app"
export AUTOREWARDER_DATA_DIR="$WORK_DIR/data"
export AUTOREWARDER_STATE_DIR="$WORK_DIR/data/state"
export AUTOREWARDER_NOTIFY_URL="https://ntfy.sh/example-private-topic"
export AUTOREWARDER_EXPECTED_HOUR=0
export AUTOREWARDER_EXPECTED_MINUTE=0
export AUTOREWARDER_START_GRACE_MINUTES=0
export FAKE_CURL_LOG="$WORK_DIR/curl.log"

FAKE_CURL_FAIL=1 bash "$SCRIPT_PATH"
if [ "$(cat "$WORK_DIR/data/state/missed-run-date")" != "$(date +%F)" ]; then
  echo "missed run date was not recorded while offline"
  exit 1
fi
if [ ! -s "$WORK_DIR/data/state/internet-outage-started-at" ]; then
  echo "outage start was not recorded while offline"
  exit 1
fi
if [ -e "$WORK_DIR/data/state/notified-missed-run-date" ]; then
  echo "offline run should not mark missed notified"
  exit 1
fi

FAKE_CURL_FAIL=0 bash "$SCRIPT_PATH"
if [ "$(cat "$WORK_DIR/data/state/notified-missed-run-date")" != "$(date +%F)" ]; then
  echo "online run should mark missed notified"
  exit 1
fi
if [ -e "$WORK_DIR/data/state/internet-outage-started-at" ]; then
  echo "outage start should clear after online notification"
  exit 1
fi
if ! grep -q "Do you want to run it now?" "$WORK_DIR/curl.log"; then
  echo "notification did not ask whether to run now"
  exit 1
fi
if ! grep -q "nohup ~/AutoRewarder/run-random-accounts.sh >/dev/null 2>&1 &" "$WORK_DIR/curl.log"; then
  echo "notification did not include run command"
  exit 1
fi
if ! grep -q "tail -n 50 ~/AutoRewarder/logs/autorewarder-" "$WORK_DIR/curl.log"; then
  echo "notification did not include log tail command"
  exit 1
fi

notify_count_before="$(grep -c -- '--data-binary' "$WORK_DIR/curl.log")"
bash "$SCRIPT_PATH"
notify_count_after="$(grep -c -- '--data-binary' "$WORK_DIR/curl.log")"
if [ "$notify_count_before" != "$notify_count_after" ]; then
  echo "notification repeated after already notified"
  exit 1
fi

rm -f "$WORK_DIR/data/state/"*
cat > "$WORK_DIR/app/logs/autorewarder-$(date +%F).log" <<LOG
===== Started $(date) PID 123 =====
Window: 6:00 through 23:59
LOG
AUTOREWARDER_MAX_RUNTIME_MINUTES=1 bash "$SCRIPT_PATH"
if [ -e "$WORK_DIR/data/state/stuck-run-date" ]; then
  echo "random account run should not be marked stuck before its run window closes"
  exit 1
fi

printf '%s\n' "$(date +%F)" > "$WORK_DIR/data/state/last-run-started"
rm -f "$WORK_DIR/data/state/missed-run-date" "$WORK_DIR/data/state/notified-missed-run-date" "$WORK_DIR/data/state/notified-outage-id"
FAKE_CURL_FAIL=1 bash "$SCRIPT_PATH"
FAKE_CURL_FAIL=0 bash "$SCRIPT_PATH"
if ! grep -q "Internet was down since" "$WORK_DIR/curl.log"; then
  echo "restored internet notification was not sent"
  exit 1
fi

bash -n "$SCRIPT_PATH"
echo "online notifier tests passed"
