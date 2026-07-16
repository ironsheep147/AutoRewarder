#!/usr/bin/env bash
set -u

APP_DIR="${APP_DIR:-$HOME/AutoRewarder}"
LOG_DIR="$APP_DIR/logs"
LOCK_FILE="${LOCK_FILE:-/tmp/autorewarder.lock}"

START_HOUR="${START_HOUR:-6}"
END_HOUR="${END_HOUR:-23}"
END_MINUTE="${END_MINUTE:-59}"
ACCOUNT_LIMIT="${ACCOUNT_LIMIT:-5}"

SEARCH_TOTAL_MIN="${SEARCH_TOTAL_MIN:-20}"
SEARCH_TOTAL_MAX="${SEARCH_TOTAL_MAX:-25}"

MIN_GAP_SECONDS="${MIN_GAP_SECONDS:-600}"
DRY_RUN="${DRY_RUN:-0}"

mkdir -p "$LOG_DIR"
find "$LOG_DIR" -type f -name "autorewarder-random-*.log" -mtime +7 -delete 2>/dev/null || true

if [ "$DRY_RUN" = "1" ]; then
  LOG_FILE="$LOG_DIR/autorewarder-random-dryrun-$(date +%F-%H%M%S)-$$.log"
else
  LOG_FILE="$LOG_DIR/autorewarder-random-$(date +%F).log"
fi

rand_between() {
  local min="$1"
  local max="$2"
  if [ "$max" -lt "$min" ]; then
    max="$min"
  fi
  python3 -c "import random; print(random.randint($min, $max))"
}

today_epoch() {
  local hour="$1"
  local minute="$2"
  date -d "$(date +%F) ${hour}:${minute}:00" +%s
}

load_accounts() {
  if [ -n "${ACCOUNT_LIST:-}" ]; then
    printf "%s\n" "$ACCOUNT_LIST" | sed '/^[[:space:]]*$/d'
    return
  fi

  python3 - <<'PY'
from src.accounts import AccountManager, GlobalSettingsManager

manager = AccountManager(GlobalSettingsManager())
manager.migrate_legacy()
for account in manager.list():
    if account.get("first_setup_done"):
        print(account["label"])
PY
}

shuffle_and_limit_accounts() {
  python3 -c '
import random
import sys

limit = int(sys.argv[1])
accounts = [line.rstrip("\n") for line in sys.stdin if line.strip()]
random.shuffle(accounts)
for account in accounts[:limit]:
    print(account)
' "$ACCOUNT_LIMIT"
}

run_account() {
  local account="$1"
  local pc="$2"
  local mobile="$3"

  if [ "$DRY_RUN" = "1" ]; then
    echo "DRY RUN: python3 -u AutoRewarder.py --headless --account \"$account\" --pc $pc --mobile $mobile"
    return 0
  fi

  python3 -u AutoRewarder.py --headless --account "$account" --pc "$pc" --mobile "$mobile"
}

{
  echo "===== Started $(date) PID $$ ====="
  echo "Window: ${START_HOUR}:00 through ${END_HOUR}:${END_MINUTE}"
  echo "Counts: total searches ${SEARCH_TOTAL_MIN}-${SEARCH_TOTAL_MAX}"

  cd "$APP_DIR" || {
    echo "ERROR: Cannot cd to $APP_DIR"
    exit 1
  }

  (
  flock -n 9 || {
    echo "Could not acquire lock: $LOCK_FILE"
    exit 1
  }

now="$(date +%s)"
start_epoch="$(today_epoch "$START_HOUR" 0)"
end_epoch="$(today_epoch "$END_HOUR" "$END_MINUTE")"

if [ "$now" -gt "$end_epoch" ]; then
  echo "Current time is after today's run window. Nothing to run."
  exit 0
fi

if [ "$now" -lt "$start_epoch" ]; then
  wait_seconds=$((start_epoch - now))
  echo "Waiting $wait_seconds seconds for the run window to open."
  if [ "$DRY_RUN" != "1" ]; then
    sleep "$wait_seconds"
  fi
  now="$start_epoch"
fi

mapfile -t accounts < <(load_accounts | shuffle_and_limit_accounts)
if [ "${#accounts[@]}" -eq 0 ]; then
  echo "No ready accounts found."
  exit 0
fi

echo "Randomized account order:"
for account in "${accounts[@]}"; do
  echo "  - $account"
done

total="${#accounts[@]}"
for index in "${!accounts[@]}"; do
  account="${accounts[$index]}"
  search_total="$(rand_between "$SEARCH_TOTAL_MIN" "$SEARCH_TOTAL_MAX")"
  pc="$(rand_between 0 "$search_total")"
  mobile=$((search_total - pc))

  echo "Running account $((index + 1))/$total: $account --pc $pc --mobile $mobile (total $search_total)"
  run_account "$account" "$pc" "$mobile"
  exit_code="$?"
  echo "Account '$account' exited with code $exit_code"

  remaining=$((total - index - 1))
  if [ "$remaining" -le 0 ]; then
    break
  fi

  now="$(date +%s)"
  seconds_left=$((end_epoch - now))
  if [ "$seconds_left" -le "$MIN_GAP_SECONDS" ]; then
    echo "Run window is nearly closed; continuing without a delay."
    continue
  fi

  max_gap=$((seconds_left / (remaining + 1)))
  if [ "$max_gap" -lt "$MIN_GAP_SECONDS" ]; then
    max_gap="$MIN_GAP_SECONDS"
  fi
  sleep_seconds="$(rand_between "$MIN_GAP_SECONDS" "$max_gap")"
  echo "Waiting $sleep_seconds seconds before the next account."
  if [ "$DRY_RUN" != "1" ]; then
    sleep "$sleep_seconds"
  fi
done
  ) 9>"$LOCK_FILE"

  echo "===== Finished $(date) ====="
  echo
} >> "$LOG_FILE" 2>&1

if [ "$DRY_RUN" = "1" ]; then
  cat "$LOG_FILE"
fi
