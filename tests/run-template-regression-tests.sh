#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TMP_DIR=$(mktemp -d)

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

assert_render_ok_contains() {
  VALUES_FILE="$1"
  PATTERN="$2"
  DESC="$3"
  OUT_FILE="$TMP_DIR/render.out"

  if ! helm template k3s-alert "$ROOT_DIR" -f "$VALUES_FILE" > "$OUT_FILE" 2>"$TMP_DIR/render.err"; then
    echo "FAIL: $DESC"
    cat "$TMP_DIR/render.err"
    exit 1
  fi

  if ! grep -qE "$PATTERN" "$OUT_FILE"; then
    echo "FAIL: $DESC"
    echo "Expected pattern: $PATTERN"
    exit 1
  fi
}

assert_render_fails_with() {
  VALUES_FILE="$1"
  PATTERN="$2"
  DESC="$3"

  if helm template k3s-alert "$ROOT_DIR" -f "$VALUES_FILE" >"$TMP_DIR/fail.out" 2>"$TMP_DIR/fail.err"; then
    echo "FAIL: $DESC"
    echo "Expected helm template to fail"
    exit 1
  fi

  if ! grep -qE "$PATTERN" "$TMP_DIR/fail.err"; then
    echo "FAIL: $DESC"
    echo "Expected error pattern: $PATTERN"
    cat "$TMP_DIR/fail.err"
    exit 1
  fi
}

# Default schedule from values.yaml
DEFAULT_VALUES="$TMP_DIR/default-values.yaml"
cat > "$DEFAULT_VALUES" <<'EOF'
{}
EOF
assert_render_ok_contains "$DEFAULT_VALUES" 'schedule: "\*/2 \* \* \* \*"' "default interval schedule should render every 2 minutes"

# Interval hours schedule
INTERVAL_HOURS_VALUES="$TMP_DIR/interval-hours.yaml"
cat > "$INTERVAL_HOURS_VALUES" <<'EOF'
schedule:
  type: interval
  intervalMinutes: null
  intervalHours: 6
  intervalDays: null
EOF
assert_render_ok_contains "$INTERVAL_HOURS_VALUES" 'schedule: "0 \*/6 \* \* \*"' "intervalHours should render expected cron"

# Cron schedule mode
CRON_VALUES="$TMP_DIR/cron-values.yaml"
cat > "$CRON_VALUES" <<'EOF'
schedule:
  type: cron
  cron: "0 */6 * * *"
EOF
assert_render_ok_contains "$CRON_VALUES" 'schedule: "0 \*/6 \* \* \*"' "cron mode should render provided cron expression"

# Invalid cron expression
BAD_CRON_VALUES="$TMP_DIR/bad-cron-values.yaml"
cat > "$BAD_CRON_VALUES" <<'EOF'
schedule:
  type: cron
  cron: "0 */6 * *"
EOF
assert_render_fails_with "$BAD_CRON_VALUES" "values\.schedule\.cron must be a 5-field cron expression" "invalid cron should fail validation"

# Invalid interval configuration (multiple interval fields)
BAD_INTERVAL_VALUES="$TMP_DIR/bad-interval-values.yaml"
cat > "$BAD_INTERVAL_VALUES" <<'EOF'
schedule:
  type: interval
  intervalMinutes: 2
  intervalHours: 1
EOF
assert_render_fails_with "$BAD_INTERVAL_VALUES" "set exactly one of values\.schedule\.intervalMinutes" "multiple interval fields should fail validation"

# valueFrom rendering for SMTP credentials and webhook url
VALUEFROM_VALUES="$TMP_DIR/valuefrom-values.yaml"
cat > "$VALUEFROM_VALUES" <<'EOF'
channels:
  email:
    enabled: true
    username:
      valueFrom:
        secretKeyRef:
          name: ext-secrets
          key: username
    password:
      valueFrom:
        secretKeyRef:
          name: ext-secrets
          key: password
  webhook:
    enabled: true
    url:
      valueFrom:
        secretKeyRef:
          name: ext-secrets
          key: webhook
EOF
assert_render_ok_contains "$VALUEFROM_VALUES" 'name: SMTP_USERNAME' "SMTP_USERNAME env should be present"
assert_render_ok_contains "$VALUEFROM_VALUES" 'name: SMTP_PASSWORD' "SMTP_PASSWORD env should be present"
assert_render_ok_contains "$VALUEFROM_VALUES" 'name: WEBHOOK_URL' "WEBHOOK_URL env should be present"
assert_render_ok_contains "$VALUEFROM_VALUES" 'secretKeyRef:' "valueFrom secretKeyRef should render for map-based inputs"

echo "Template regression tests: OK"