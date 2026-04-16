#!/bin/sh
set -eu

CHART_DIR=${1:-.}
OUT_FILE=${2:-/tmp/k3s-alert-check.sh}

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
"$SCRIPT_DIR/extract-rendered-check.sh" "$CHART_DIR" "$OUT_FILE"

sh -n "$OUT_FILE"
echo "Shell syntax check: OK"

if command -v shellcheck >/dev/null 2>&1; then
  shellcheck -S warning "$OUT_FILE"
  echo "Shellcheck: OK"
else
  echo "Shellcheck: not installed (skipped)"
fi
