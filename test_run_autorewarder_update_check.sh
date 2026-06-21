#!/usr/bin/env bash
set -euo pipefail

SCRIPT_PATH="${1:-run-autorewarder.sh}"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

helper_code="$({
  awk '/^has_blocking_local_changes\(\)/,/^}/ { print }' "$SCRIPT_PATH"
  awk '/^restore_generated_query_changes\(\)/,/^}/ { print }' "$SCRIPT_PATH"
})"
if [ -z "$helper_code" ]; then
  echo "missing update sync helpers"
  exit 1
fi

eval "$helper_code"

cd "$WORK_DIR"
git init -q
git config user.email "test@example.com"
git config user.name "Test User"

mkdir -p assets
echo 'base' > assets/queries.json
echo 'base' > app.py
git add assets/queries.json app.py
git commit -q -m init

echo 'generated' > assets/queries.json
if has_blocking_local_changes; then
  echo "generated queries.json should not block update sync"
  exit 1
fi

echo 'changed' > app.py
if ! has_blocking_local_changes; then
  echo "unstaged code change should block update sync"
  exit 1
fi

git add app.py
if ! has_blocking_local_changes; then
  echo "staged code change should block update sync"
  exit 1
fi

git reset -q HEAD app.py
git checkout -q -- app.py
git checkout -q -b next
echo 'branch version' > assets/queries.json
git add assets/queries.json
git commit -q -m 'branch query version'
git checkout -q master
echo 'generated again' > assets/queries.json
restore_generated_query_changes
git checkout -q next
