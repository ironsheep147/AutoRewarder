#!/usr/bin/env bash
set -u

APP_DIR="$HOME/AutoRewarder"
LOG_DIR="$APP_DIR/logs"
LOCK_FILE="${LOCK_FILE:-/tmp/autorewarder.lock}"

mkdir -p "$LOG_DIR"

# Delete logs older than 7 days
find "$LOG_DIR" -type f -name "autorewarder-*.log" -mtime +7 -delete 2>/dev/null || true

LOG_FILE="$LOG_DIR/autorewarder-$(date +%F).log"
RANDOM_WAIT_MAX_SECONDS="${AUTOREWARDER_RANDOM_WAIT_MAX_SECONDS:-5800}"

random_wait_seconds() {
  if [ -n "${AUTOREWARDER_RANDOM_WAIT_SECONDS:-}" ]; then
    echo "$AUTOREWARDER_RANDOM_WAIT_SECONDS"
    return 0
  fi

  if ! [[ "$RANDOM_WAIT_MAX_SECONDS" =~ ^[0-9]+$ ]] || [ "$RANDOM_WAIT_MAX_SECONDS" -le 0 ]; then
    echo 0
    return 0
  fi

  echo $((RANDOM % RANDOM_WAIT_MAX_SECONDS))
}

wait_random_after_updates() {
  local wait_seconds

  wait_seconds="$(random_wait_seconds)"
  if ! [[ "$wait_seconds" =~ ^[0-9]+$ ]]; then
    echo "WARNING: Invalid random wait seconds: $wait_seconds. Skipping wait."
    return 0
  fi

  if [ "$wait_seconds" -le 0 ]; then
    echo "Random wait skipped (0 seconds)."
    return 0
  fi

  echo "Waiting $wait_seconds seconds before running AutoRewarder..."
  sleep "$wait_seconds"
}

latest_main_release_tag() {
  git describe --tags --match "v[0-9]*" --abbrev=0 main 2>/dev/null || true
}

latest_available_release_tag() {
  git tag -l "v[0-9]*" --sort=-v:refname | head -n 1
}

version_gt() {
  local newer="$1"
  local older="$2"

  [ -n "$newer" ] || return 1
  [ -n "$older" ] || return 0
  [ "$newer" != "$older" ] || return 1
  [ "$(printf "%s\n%s\n" "$newer" "$older" | sort -V | tail -n 1)" = "$newer" ]
}

sync_fork_if_new_release() {
  local current_tag
  local latest_tag
  local original_branch

  echo "Checking upstream release tags..."
  current_tag="$(latest_main_release_tag)"
  if [ -n "$current_tag" ]; then
    echo "Current main release: $current_tag"
  else
    echo "Current main release: none"
  fi

  git fetch upstream --tags || return 1

  latest_tag="$(latest_available_release_tag)"
  if [ -z "$latest_tag" ]; then
    echo "No upstream release tags found. Skipping fork sync."
    return 0
  fi

  echo "Latest available release: $latest_tag"
  if ! version_gt "$latest_tag" "$current_tag"; then
    echo "No newer upstream release found. Skipping fork sync."
    return 0
  fi

  if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "ERROR: Working tree has local changes. Resolve them before syncing."
    return 1
  fi

  original_branch="$(git branch --show-current)"
  if [ "$original_branch" != "autorun" ]; then
    echo "ERROR: Expected to run from autorun branch, found '$original_branch'."
    return 1
  fi

  echo "New upstream release found: $latest_tag"
  echo "Fast-forwarding main from upstream/main..."
  git checkout main || return 1
  git merge --ff-only upstream/main || return 1
  git push origin main || return 1

  echo "Rebasing autorun on updated main..."
  git checkout autorun || return 1
  git rebase main || return 1
  git push --force-with-lease origin autorun || return 1

  echo "Fork synced to upstream release $latest_tag."
}

{
  echo "===== Started $(date) PID $$ ====="

  cd "$APP_DIR" || {
    echo "ERROR: Cannot cd to $APP_DIR"
    exit 1
  }

  (
    flock -n 9 || {
      echo "Could not acquire lock: $LOCK_FILE"
      exit 1
    }

    sync_fork_if_new_release || {
      echo "ERROR: Upstream release sync failed. Not running AutoRewarder."
      exit 1
    }

    echo "Updating search queries from Google Trends..."
    if ! python3 -u update_queries.py update --mode combine --timeout 60; then
      echo "WARNING: Query update failed. Continuing with existing queries."
    fi

    wait_random_after_updates

    echo "Randomizing account schedules..."
    python3 -u schedule_randomizer.py

    echo "Running AutoRewarder..."
    python3 -u AutoRewarder.py --headless
    exit_code="$?"

    echo "AutoRewarder exited with code $exit_code"
    exit "$exit_code"
  ) 9>"$LOCK_FILE"

  echo "===== Finished $(date) ====="
  echo
} >> "$LOG_FILE" 2>&1
