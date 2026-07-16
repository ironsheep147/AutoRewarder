#!/usr/bin/env bash
set -u

APP_DIR="${AUTOREWARDER_APP_DIR:-$HOME/AutoRewarder}"
DATA_DIR="${AUTOREWARDER_DATA_DIR:-$HOME/.local/share/AutoRewarder}"
STATE_DIR="${AUTOREWARDER_STATE_DIR:-$DATA_DIR/state}"
LOG_DIR="$APP_DIR/logs"
LOG_FILE="$LOG_DIR/online-notifier-$(date +%F).log"

RUN_MARKER_FILE="$STATE_DIR/last-run-started"
MISSED_FILE="$STATE_DIR/missed-run-date"
NOTIFIED_MISSED_FILE="$STATE_DIR/notified-missed-run-date"
OUTAGE_START_FILE="$STATE_DIR/internet-outage-started-at"
NOTIFIED_OUTAGE_FILE="$STATE_DIR/notified-outage-id"
FAILED_FILE="$STATE_DIR/failed-run-date"
STUCK_FILE="$STATE_DIR/stuck-run-date"
NOTIFIED_FAILED_FILE="$STATE_DIR/notified-failed-run-date"
NOTIFIED_STUCK_FILE="$STATE_DIR/notified-stuck-run-date"

EXPECTED_HOUR="${AUTOREWARDER_EXPECTED_HOUR:-4}"
EXPECTED_MINUTE="${AUTOREWARDER_EXPECTED_MINUTE:-0}"
START_GRACE_MINUTES="${AUTOREWARDER_START_GRACE_MINUTES:-10}"
MAX_RUNTIME_MINUTES="${AUTOREWARDER_MAX_RUNTIME_MINUTES:-240}"
NOTIFY_URL="${AUTOREWARDER_NOTIFY_URL:-}"
PING_URL="${AUTOREWARDER_PING_URL:-https://www.google.com/generate_204}"
TODAY_RUN_LOG="$LOG_DIR/autorewarder-$(date +%F).log"
RUN_COMMAND='nohup ~/AutoRewarder/run-random-accounts.sh >/dev/null 2>&1 &'

mkdir -p "$STATE_DIR" "$LOG_DIR"

log() {
  printf '[%s] %s\n' "$(date -Is)" "$*" >> "$LOG_FILE"
}

today() {
  date +%F
}

now_epoch() {
  date +%s
}

deadline_epoch() {
  date -d "$(today) ${EXPECTED_HOUR}:${EXPECTED_MINUTE}:00 + ${START_GRACE_MINUTES} minutes" +%s
}

online() {
  command -v curl >/dev/null 2>&1 || return 1
  curl -fsS --max-time 10 "$PING_URL" >/dev/null 2>&1
}

notify() {
  local title="$1"
  local message="$2"

  if [ -z "$NOTIFY_URL" ]; then
    printf '%s\n\n%s\n' "$title" "$message"
    return 0
  fi

  curl -fsS --max-time 20 \
    -H "Title: $title" \
    --data-binary "$message" \
    "$NOTIFY_URL" >/dev/null
}

run_started_today() {
  local date_today marker_date
  date_today="$(today)"
  marker_date="$(cat "$RUN_MARKER_FILE" 2>/dev/null || true)"

  [ "$marker_date" = "$date_today" ] && return 0
  [ -f "$TODAY_RUN_LOG" ] || return 1
  grep -q "===== Started" "$TODAY_RUN_LOG"
}

run_finished_today() {
  [ -f "$TODAY_RUN_LOG" ] || return 1
  grep -q "===== Finished" "$TODAY_RUN_LOG"
}

run_failed_today() {
  [ -f "$TODAY_RUN_LOG" ] || return 1
  grep -Eq "AutoRewarder exited with code [1-9][0-9]*|ERROR:" "$TODAY_RUN_LOG"
}

mark_run_problems_if_needed() {
  local date_today started_epoch max_end
  date_today="$(today)"

  if [ "$(now_epoch)" -ge "$(deadline_epoch)" ] && ! run_started_today; then
    if [ "$(cat "$MISSED_FILE" 2>/dev/null || true)" != "$date_today" ]; then
      printf '%s\n' "$date_today" > "$MISSED_FILE"
      log "Marked missed run for $date_today"
    fi
  fi

  if run_failed_today; then
    if [ "$(cat "$FAILED_FILE" 2>/dev/null || true)" != "$date_today" ]; then
      printf '%s\n' "$date_today" > "$FAILED_FILE"
      log "Marked failed run for $date_today"
    fi
  fi

  if run_started_today && ! run_finished_today; then
    started_epoch="$(date -d "$(today) ${EXPECTED_HOUR}:${EXPECTED_MINUTE}:00" +%s)"
    max_end=$(( started_epoch + MAX_RUNTIME_MINUTES * 60 ))
    if [ "$(now_epoch)" -ge "$max_end" ] && [ "$(cat "$STUCK_FILE" 2>/dev/null || true)" != "$date_today" ]; then
      printf '%s\n' "$date_today" > "$STUCK_FILE"
      log "Marked stuck run for $date_today"
    fi
  fi
}

record_offline_or_send_once() {
  local date_today missed_date failed_date stuck_date notified_missed notified_failed notified_stuck outage_start outage_id notified_outage title message
  date_today="$(today)"

  if ! online; then
    [ -s "$OUTAGE_START_FILE" ] || date -Is > "$OUTAGE_START_FILE"
    log "Offline; waiting to notify when back online"
    return 0
  fi

  missed_date="$(cat "$MISSED_FILE" 2>/dev/null || true)"
  failed_date="$(cat "$FAILED_FILE" 2>/dev/null || true)"
  stuck_date="$(cat "$STUCK_FILE" 2>/dev/null || true)"
  notified_missed="$(cat "$NOTIFIED_MISSED_FILE" 2>/dev/null || true)"
  notified_failed="$(cat "$NOTIFIED_FAILED_FILE" 2>/dev/null || true)"
  notified_stuck="$(cat "$NOTIFIED_STUCK_FILE" 2>/dev/null || true)"
  outage_start="$(cat "$OUTAGE_START_FILE" 2>/dev/null || true)"
  outage_id="${outage_start:-}"
  notified_outage="$(cat "$NOTIFIED_OUTAGE_FILE" 2>/dev/null || true)"

  [ "$missed_date" = "$date_today" ] && [ "$notified_missed" != "$date_today" ] || missed_date=""
  [ "$failed_date" = "$date_today" ] && [ "$notified_failed" != "$date_today" ] || failed_date=""
  [ "$stuck_date" = "$date_today" ] && [ "$notified_stuck" != "$date_today" ] || stuck_date=""
  [ -n "$outage_start" ] && [ "$notified_outage" != "$outage_id" ] || outage_start=""

  [ -n "$missed_date$failed_date$stuck_date$outage_start" ] || return 0

  title="AutoRewarder check needed"
  message="Internet is online now."
  if [ -n "$outage_start" ]; then
    message="$message Internet was down since $outage_start."
  fi
  if [ -n "$missed_date" ]; then
    message="$message AutoRewarder did not start at ${EXPECTED_HOUR}:${EXPECTED_MINUTE} today."
  fi
  if [ -n "$failed_date" ]; then
    message="$message AutoRewarder log shows failure."
  fi
  if [ -n "$stuck_date" ]; then
    message="$message AutoRewarder log shows start but no finish after ${MAX_RUNTIME_MINUTES} minutes."
  fi
  message="$message Check log with: tail -n 50 ~/AutoRewarder/logs/autorewarder-$(date +%F).log . Do you want to run it now? Command: $RUN_COMMAND"

  if notify "$title" "$message"; then
    [ -n "$missed_date" ] && printf '%s\n' "$date_today" > "$NOTIFIED_MISSED_FILE"
    [ -n "$failed_date" ] && printf '%s\n' "$date_today" > "$NOTIFIED_FAILED_FILE"
    [ -n "$stuck_date" ] && printf '%s\n' "$date_today" > "$NOTIFIED_STUCK_FILE"
    if [ -n "$outage_start" ]; then
      printf '%s\n' "$outage_id" > "$NOTIFIED_OUTAGE_FILE"
      rm -f "$OUTAGE_START_FILE"
    fi
    log "Sent one-time notification"
  else
    log "Notification send failed; will retry next tick"
  fi
}

main() {
  mark_run_problems_if_needed
  record_offline_or_send_once
}

main "$@"
