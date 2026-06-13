#!/usr/bin/env bash
set -u

APP_DIR="$HOME/AutoRewarder"
LOG_DIR="$APP_DIR/logs"
LOCK_FILE="/tmp/autorewarder.lock"

mkdir -p "$LOG_DIR"

# Delete logs older than 7 days
find "$LOG_DIR" -type f -name "autorewarder-*.log" -mtime +7 -delete 2>/dev/null || true

LOG_FILE="$LOG_DIR/autorewarder-$(date +%F).log"

{
  echo "===== Started $(date) PID $$ ====="

  cd "$APP_DIR" || {
    echo "ERROR: Cannot cd to $APP_DIR"
    exit 1
  }

  flock -n "$LOCK_FILE" bash -c '
    echo "Running git pull..."
    git pull

    echo "Randomizing account schedules..."
    python3 -u schedule_randomizer.py

    echo "Running AutoRewarder..."
    python3 -u AutoRewarder.py --headless

    echo "AutoRewarder exited with code $?"
  '

  echo "===== Finished $(date) ====="
  echo
} >> "$LOG_FILE" 2>&1
