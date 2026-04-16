#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TMP_DIR=$(mktemp -d)
MOCK_BIN="$TMP_DIR/mock-bin"
STATE_DIR="$TMP_DIR/state"
mkdir -p "$MOCK_BIN" "$STATE_DIR"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

NOTIFIED_FILE="$STATE_DIR/notified_keys"
LAST_SENT_FILE="$STATE_DIR/last_sent"
BACKOFF_HASH_FILE="$STATE_DIR/backoff_hash"
BACKOFF_LEVEL_FILE="$STATE_DIR/backoff_level"
BACKOFF_NEXT_FILE="$STATE_DIR/backoff_next"
RATE_FILE="$STATE_DIR/email_rate"
CURL_CALLS_FILE="$STATE_DIR/curl_calls"
PODS_TABLE_FILE="$STATE_DIR/pods_table"
PODS_JSONPATH_FILE="$STATE_DIR/pods_jsonpath"
NODES_FILE="$STATE_DIR/nodes"
EVENTS_FILE="$STATE_DIR/events"
DEPLOYMENTS_FILE="$STATE_DIR/deployments"

: > "$NOTIFIED_FILE"
echo 0 > "$LAST_SENT_FILE"
: > "$BACKOFF_HASH_FILE"
echo 0 > "$BACKOFF_LEVEL_FILE"
echo 0 > "$BACKOFF_NEXT_FILE"
: > "$RATE_FILE"
: > "$CURL_CALLS_FILE"
: > "$PODS_TABLE_FILE"
: > "$PODS_JSONPATH_FILE"
echo "node1|Ready=True;MemoryPressure=False;DiskPressure=False;PIDPressure=False;" > "$NODES_FILE"
: > "$EVENTS_FILE"
cat > "$DEPLOYMENTS_FILE" <<'EOF'
kube-system coredns 2/2 2 2 1d
kube-system metrics-server 1/1 1 1 1d
kube-system local-path-provisioner 1/1 1 1 1d
EOF

cat > "$MOCK_BIN/kubectl" <<'EOF'
#!/bin/sh
set -eu

STATE_DIR=${MOCK_STATE_DIR:?}
NOTIFIED_FILE="$STATE_DIR/notified_keys"
LAST_SENT_FILE="$STATE_DIR/last_sent"
BACKOFF_HASH_FILE="$STATE_DIR/backoff_hash"
BACKOFF_LEVEL_FILE="$STATE_DIR/backoff_level"
BACKOFF_NEXT_FILE="$STATE_DIR/backoff_next"
RATE_FILE="$STATE_DIR/email_rate"
PODS_TABLE_FILE="$STATE_DIR/pods_table"
PODS_JSONPATH_FILE="$STATE_DIR/pods_jsonpath"
NODES_FILE="$STATE_DIR/nodes"
EVENTS_FILE="$STATE_DIR/events"
DEPLOYMENTS_FILE="$STATE_DIR/deployments"

if [ "$1" = "get" ] && [ "$2" = "configmap" ] && [ "$3" = "k3s-alert-state" ]; then
  case "$*" in
    *"jsonpath={.data.notified_keys}"*) cat "$NOTIFIED_FILE" ;;
    *"jsonpath={.data.last_sent}"*) cat "$LAST_SENT_FILE" ;;
    *"jsonpath={.data.backoff_hash}"*) cat "$BACKOFF_HASH_FILE" ;;
    *"jsonpath={.data.backoff_level}"*) cat "$BACKOFF_LEVEL_FILE" ;;
    *"jsonpath={.data.backoff_next_allowed}"*) cat "$BACKOFF_NEXT_FILE" ;;
    *"jsonpath={.data.email_rate_history}"*) cat "$RATE_FILE" ;;
    *) : ;;
  esac
  exit 0
fi

if [ "$1" = "get" ] && [ "$2" = "pods" ] && [ "$3" = "-A" ] && [ "$4" = "--no-headers" ]; then
  cat "$PODS_TABLE_FILE"
  exit 0
fi

if [ "$1" = "get" ] && [ "$2" = "pods" ] && [ "$3" = "-A" ]; then
  case "$*" in
    *"-o jsonpath="*) cat "$PODS_JSONPATH_FILE" ;;
    *) : ;;
  esac
  exit 0
fi

if [ "$1" = "get" ] && [ "$2" = "nodes" ]; then
  cat "$NODES_FILE"
  exit 0
fi

if [ "$1" = "get" ] && [ "$2" = "events" ]; then
  cat "$EVENTS_FILE"
  exit 0
fi

if [ "$1" = "get" ] && [ "$2" = "deployments" ] && [ "$3" = "-A" ]; then
  cat "$DEPLOYMENTS_FILE"
  exit 0
fi

if [ "$1" = "create" ] && [ "$2" = "configmap" ] && [ "$3" = "k3s-alert-state" ]; then
  shift 3
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --from-file=notified_keys=*) cat "${1#--from-file=notified_keys=}" > "$NOTIFIED_FILE" ;;
      --from-file=email_rate_history=*) cat "${1#--from-file=email_rate_history=}" > "$RATE_FILE" ;;
      --from-literal=last_sent=*) printf '%s' "${1#--from-literal=last_sent=}" > "$LAST_SENT_FILE" ;;
      --from-literal=backoff_hash=*) printf '%s' "${1#--from-literal=backoff_hash=}" > "$BACKOFF_HASH_FILE" ;;
      --from-literal=backoff_level=*) printf '%s' "${1#--from-literal=backoff_level=}" > "$BACKOFF_LEVEL_FILE" ;;
      --from-literal=backoff_next_allowed=*) printf '%s' "${1#--from-literal=backoff_next_allowed=}" > "$BACKOFF_NEXT_FILE" ;;
      *) : ;;
    esac
    shift
  done
  echo "apiVersion: v1"
  echo "kind: ConfigMap"
  echo "metadata:"
  echo "  name: k3s-alert-state"
  exit 0
fi

if [ "$1" = "apply" ] && [ "$2" = "-f" ]; then
  exit 0
fi

if [ "$1" = "annotate" ]; then
  exit 0
fi

exit 0
EOF

cat > "$MOCK_BIN/curl" <<'EOF'
#!/bin/sh
set -eu
echo call >> "${MOCK_CURL_CALLS_FILE:?}"
exit 0
EOF

chmod +x "$MOCK_BIN/kubectl" "$MOCK_BIN/curl"

RENDERED_SCRIPT="$TMP_DIR/check.sh"
"$ROOT_DIR/tests/extract-rendered-check.sh" "$ROOT_DIR" "$RENDERED_SCRIPT"
chmod +x "$RENDERED_SCRIPT"

run_script() {
  env \
    PATH="$MOCK_BIN:$PATH" \
    MOCK_STATE_DIR="$STATE_DIR" \
    MOCK_CURL_CALLS_FILE="$CURL_CALLS_FILE" \
    SMTP_HOST="smtp.test.local" \
    SMTP_PORT="587" \
    SMTP_FROM="from@test.local" \
    SMTP_TO="to@test.local" \
    SMTP_USERNAME="user" \
    SMTP_PASSWORD="pass" \
    SMTP_MAIL_FORMAT="structured" \
    SMTP_SUBJECT_PREFIX="TEST" \
    SMTP_MAX_LINES_PER_SECTION="5" \
    "$RENDERED_SCRIPT"
}

echo "default testpod 0/1 Running 0 1m" > "$PODS_TABLE_FILE"
echo "default testpod container1::OOMKilled;" > "$PODS_JSONPATH_FILE"

RUN1_OUT="$TMP_DIR/run1.log"
run_script > "$RUN1_OUT"
if ! grep -q "Alert delivery: sent=1" "$RUN1_OUT"; then
  echo "FAIL: expected first run to send alert"
  cat "$RUN1_OUT"
  exit 1
fi

RUN2_OUT="$TMP_DIR/run2.log"
run_script > "$RUN2_OUT"
if ! grep -q "No new issues (active issues already notified)" "$RUN2_OUT"; then
  echo "FAIL: expected second run to suppress duplicate alert"
  cat "$RUN2_OUT"
  exit 1
fi

echo "default testpod 1/1 Running 0 1m" > "$PODS_TABLE_FILE"
: > "$PODS_JSONPATH_FILE"
RUN3_OUT="$TMP_DIR/run3.log"
run_script > "$RUN3_OUT"
if ! grep -q "No issues" "$RUN3_OUT"; then
  echo "FAIL: expected third run to detect resolution"
  cat "$RUN3_OUT"
  exit 1
fi

# Reset persisted cooldown for deterministic reappearance assertion.
echo 0 > "$LAST_SENT_FILE"
echo 0 > "$BACKOFF_LEVEL_FILE"
echo 0 > "$BACKOFF_NEXT_FILE"
: > "$BACKOFF_HASH_FILE"

echo "default testpod 0/1 Running 0 1m" > "$PODS_TABLE_FILE"
echo "default testpod container1::OOMKilled;" > "$PODS_JSONPATH_FILE"
RUN4_OUT="$TMP_DIR/run4.log"
run_script > "$RUN4_OUT"
if ! grep -q "Alert delivery: sent=1" "$RUN4_OUT"; then
  echo "FAIL: expected fourth run to re-alert after reappearance"
  cat "$RUN4_OUT"
  exit 1
fi

CALLS=$(wc -l < "$CURL_CALLS_FILE" | tr -d ' ')
if [ "$CALLS" -ne 2 ]; then
  echo "FAIL: expected exactly 2 outbound notifications, got $CALLS"
  exit 1
fi

echo "Mock integration tests: OK"
