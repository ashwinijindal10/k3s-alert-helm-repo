#!/bin/sh
set -eu

CHART_DIR=${1:-.}
OUT_FILE=${2:-/tmp/k3s-alert-check.sh}
RELEASE_NAME=${3:-k3s-alert}
NAMESPACE=${4:-kube-system}

TMP_RENDER=$(mktemp)
helm template "$RELEASE_NAME" "$CHART_DIR" -n "$NAMESPACE" > "$TMP_RENDER"

awk '
  BEGIN { in_target_cm = 0; in_script = 0 }
  /^kind: ConfigMap$/ { in_target_cm = 0; in_script = 0 }
  /^metadata:$/ { in_meta = 1; next }
  in_meta && /^  name: k3s-alert-script$/ { in_target_cm = 1; in_meta = 0; next }
  in_target_cm && /^  check.sh: \|$/ { in_script = 1; next }
  in_script {
    if ($0 ~ /^[^ ]/) { exit }
    sub(/^    /, "")
    print
  }
' "$TMP_RENDER" > "$OUT_FILE"

rm -f "$TMP_RENDER"

if [ ! -s "$OUT_FILE" ]; then
  echo "Failed to extract rendered check.sh" >&2
  exit 1
fi

echo "Extracted rendered script to $OUT_FILE"