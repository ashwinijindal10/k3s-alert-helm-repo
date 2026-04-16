#!/bin/sh
set -eu

STATE_CONFIGMAP="k3s-alert-state"
STATE_NAMESPACE=$(cat /var/run/secrets/kubernetes.io/serviceaccount/namespace 2>/dev/null || echo default)

STATE_NOTIFIED_KEYS_FILE="/tmp/state_notified_keys"
CURRENT_ACTIVE_KEYS_FILE="/tmp/current_active_keys"
NEW_ALERT_KEYS_FILE="/tmp/new_alert_keys"
NEXT_NOTIFIED_KEYS_FILE="/tmp/next_notified_keys"
EMAIL_RATE_FILE="/tmp/email_rate_limit"

COOLDOWN={{ .Values.cooldownSeconds }}
BACKOFF_ENABLED={{ .Values.backoff.enabled }}
BACKOFF_FILTER_MODE="{{ .Values.backoff.filterMode }}"
BACKOFF_BASE_DELAY={{ .Values.backoff.baseDelaySeconds }}
BACKOFF_FACTOR={{ .Values.backoff.factor }}
BACKOFF_MAX_DELAY={{ .Values.backoff.maxDelaySeconds }}
RATE_LIMIT_ENABLED={{ .Values.rateLimit.enabled }}
RATE_LIMIT_PERIOD={{ .Values.rateLimit.periodSeconds }}
RATE_LIMIT_MAX_EMAILS={{ .Values.rateLimit.maxEmails }}
POD_RESTART_THRESHOLD={{ .Values.alerts.podRestartThreshold }}
# shellcheck disable=SC2034
WARNING_EVENTS_SURGE="${ALERT_WARNING_EVENTS_SURGE:-false}"
WARNING_EVENTS_SURGE_THRESHOLD="${ALERT_WARNING_EVENTS_SURGE_THRESHOLD:-25}"
PENDING_UNSCHEDULABLE_MIN_PODS="${ALERT_PENDING_UNSCHEDULABLE_MIN_PODS:-1}"
DEPLOYMENT_HEALTH_TARGETS="{{ join "," .Values.deploymentsHealthCheck.targets }}"
DEPLOYMENT_HEALTH_MIN_READY_PERCENT={{ .Values.deploymentsHealthCheck.settings.minReadyPercent }}
DEPLOYMENT_HEALTH_INCLUDE_ZERO_DESIRED={{ .Values.deploymentsHealthCheck.settings.includeZeroDesired }}
DEPLOYMENT_HEALTH_MAX_REPORTED_LINES={{ .Values.deploymentsHealthCheck.settings.maxReportedLines }}
DEPLOYMENT_HEALTH_INCLUDE_MISSING_TARGETS={{ .Values.deploymentsHealthCheck.settings.includeMissingTargets }}

MAX_NOTIFIED_KEYS=5000
MAX_EMAIL_RATE_LINES=2000
MAX_STATE_CONFIGMAP_BYTES=900000
MAX_NOTIFIED_KEYS_BYTES=650000
MAX_EMAIL_RATE_BYTES=180000
MAX_STATE_SIZE_PRUNE_ATTEMPTS=8

RUN_START_TS=$(date +%s)
API_CALLS=0
LAST_SENT_TS=0
BACKOFF_HASH_STATE=""
BACKOFF_LEVEL_STATE=0
BACKOFF_NEXT_ALLOWED_STATE=0
STATE_PERSISTENCE_OK=1

ALERTS=""
RAW_ALERTS=""
RESTART_ALERT_TARGETS=""
EXCLUDE_NAMESPACES="{{ join "|" .Values.filters.excludeNamespaces }}"

run_kubectl() {
  API_CALLS=$((API_CALLS + 1))
  kubectl "$@" 2>/dev/null || true
}

run_kubectl_strict() {
  API_CALLS=$((API_CALLS + 1))
  kubectl "$@"
}

normalize_non_negative_int() {
  RAW="$1"
  FALLBACK="$2"
  case "$RAW" in
    ''|*[!0-9]*) echo "$FALLBACK" ;;
    *) echo "$RAW" ;;
  esac
}

filter_excluded_namespaces() {
  INPUT="$1"
  if [ -z "$EXCLUDE_NAMESPACES" ]; then
    printf '%s' "$INPUT"
  else
    printf '%s\n' "$INPUT" | grep -Ev "^($EXCLUDE_NAMESPACES)[[:space:]]" || true
  fi
}

count_non_empty_lines() {
  printf '%s\n' "$1" | sed '/^$/d' | wc -l | tr -d ' '
}

{{ tpl (.Files.Get "files/scripts/lib/state.sh.tpl") . }}
{{ tpl (.Files.Get "files/scripts/lib/policy.sh.tpl") . }}
{{ tpl (.Files.Get "files/scripts/lib/detection.sh.tpl") . }}
{{ tpl (.Files.Get "files/scripts/lib/notify.sh.tpl") . }}

emit_runtime_metrics() {
  END_TS=$(date +%s)
  DURATION_SEC=$((END_TS - RUN_START_TS))
  POD_ROWS=$(count_non_empty_lines "${PODS:-}")
  NODE_ROWS=$(count_non_empty_lines "${NODES_STATUS:-}")
  WARN_ROWS=$(count_non_empty_lines "${WARNING_EVENTS:-}")
  echo "Run metrics: durationSec=$DURATION_SEC apiCalls=$API_CALLS podRows=$POD_ROWS nodeRows=$NODE_ROWS warningEventRows=$WARN_ROWS totalAlerts=${TOTAL_COUNT:-0} stateOk=$STATE_PERSISTENCE_OK"
}


append_csv() {
  VAR_NAME="$1"
  VALUE="$2"
  eval "CURRENT=\${$VAR_NAME:-}"
  if [ -z "$CURRENT" ]; then
    eval "$VAR_NAME=\"$VALUE\""
  else
    eval "$VAR_NAME=\"$CURRENT,$VALUE\""
  fi
}

count_section_lines() {
  SECTION="$1"
  printf '%s\n' "$FULL_BODY" | awk -v sec="$SECTION" '
    $0 == "[" sec "]" { in_sec = 1; next }
    $0 ~ /^\[/ { in_sec = 0 }
    in_sec && NF { c++ }
    END { print c + 0 }
  '
}

render_section_lines() {
  SECTION="$1"
  LIMIT="$2"
  printf '%s\n' "$FULL_BODY" | awk -v sec="$SECTION" -v lim="$LIMIT" '
    $0 == "[" sec "]" { in_sec = 1; next }
    $0 ~ /^\[/ { in_sec = 0 }
    in_sec && NF {
      if (c < lim) {
        print
      }
      c++
    }
  '
}


PENDING_UNSCHEDULABLE_MIN_PODS=$(normalize_non_negative_int "$PENDING_UNSCHEDULABLE_MIN_PODS" "1")
WARNING_EVENTS_SURGE_THRESHOLD=$(normalize_non_negative_int "$WARNING_EVENTS_SURGE_THRESHOLD" "25")
DEPLOYMENT_HEALTH_MIN_READY_PERCENT=$(normalize_non_negative_int "$DEPLOYMENT_HEALTH_MIN_READY_PERCENT" "100")
DEPLOYMENT_HEALTH_MAX_REPORTED_LINES=$(normalize_non_negative_int "$DEPLOYMENT_HEALTH_MAX_REPORTED_LINES" "10")

load_persistent_state

echo "Running checks..."

PODS=$(run_kubectl get pods -A --no-headers)
NODES_STATUS=$(run_kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{range .status.conditions[*]}{.type}{"="}{.status}{";"}{end}{"\n"}{end}')
PODS=$(filter_excluded_namespaces "$PODS")

WARNING_EVENTS=""
{{- if or .Values.alerts.warningEventsSurge .Values.alerts.probeFailures }}
WARNING_EVENTS=$(run_kubectl get events -A --field-selector type=Warning --sort-by=.lastTimestamp --no-headers | tail -n 200 || true)
WARNING_EVENTS=$(filter_excluded_namespaces "$WARNING_EVENTS")
{{- end }}

run_app_checks
run_cluster_checks

RAW_ALERTS="$ALERTS"
filter_new_alerts

if [ -z "$RAW_ALERTS" ]; then
  echo "No issues"
  build_next_notified_state 0
  save_persistent_state 0 || true
  emit_runtime_metrics
  exit 0
fi

if [ -z "$ALERTS" ]; then
  echo "No new issues (active issues already notified)"
  build_next_notified_state 0
  save_persistent_state 0 || true
  emit_runtime_metrics
  exit 0
fi

FULL_BODY=$(printf '%b\n' "$ALERTS" | sed '/^$/d')
CRASH_COUNT=$(count_section_lines "CrashLoop")
IMAGE_COUNT=$(count_section_lines "ImagePull")
ERROR_COUNT=$(count_section_lines "Errors")
OOM_COUNT=$(count_section_lines "OOMKilled")
EVICTED_COUNT=$(count_section_lines "Evicted")
PENDING_UNSCHEDULABLE_COUNT=$(count_section_lines "PendingUnschedulable")
PROBE_FAIL_COUNT=$(count_section_lines "ProbeFailures")
WARNING_SURGE_COUNT=$(count_section_lines "WarningEventSurge")
NODE_NOT_READY_COUNT=$(count_section_lines "NodeNotReady")
NODE_PRESSURE_COUNT=$(count_section_lines "NodePressure")
DEPLOYMENTS_HEALTH_COUNT=$(count_section_lines "DeploymentsHealth")
POD_RESTART_COUNT=$(count_section_lines "PodRestarts")
TOTAL_COUNT=$((CRASH_COUNT + IMAGE_COUNT + ERROR_COUNT + OOM_COUNT + EVICTED_COUNT + PENDING_UNSCHEDULABLE_COUNT + PROBE_FAIL_COUNT + WARNING_SURGE_COUNT + NODE_NOT_READY_COUNT + NODE_PRESSURE_COUNT + DEPLOYMENTS_HEALTH_COUNT + POD_RESTART_COUNT))

DETECTED_ALERTS=""
[ "$CRASH_COUNT" -gt 0 ] && append_csv DETECTED_ALERTS "CrashLoop:$CRASH_COUNT"
[ "$IMAGE_COUNT" -gt 0 ] && append_csv DETECTED_ALERTS "ImagePull:$IMAGE_COUNT"
[ "$ERROR_COUNT" -gt 0 ] && append_csv DETECTED_ALERTS "Errors:$ERROR_COUNT"
[ "$OOM_COUNT" -gt 0 ] && append_csv DETECTED_ALERTS "OOMKilled:$OOM_COUNT"
[ "$EVICTED_COUNT" -gt 0 ] && append_csv DETECTED_ALERTS "Evicted:$EVICTED_COUNT"
[ "$PENDING_UNSCHEDULABLE_COUNT" -gt 0 ] && append_csv DETECTED_ALERTS "PendingUnschedulable:$PENDING_UNSCHEDULABLE_COUNT"
[ "$PROBE_FAIL_COUNT" -gt 0 ] && append_csv DETECTED_ALERTS "ProbeFailures:$PROBE_FAIL_COUNT"
[ "$WARNING_SURGE_COUNT" -gt 0 ] && append_csv DETECTED_ALERTS "WarningEventSurge:$WARNING_SURGE_COUNT"
[ "$NODE_NOT_READY_COUNT" -gt 0 ] && append_csv DETECTED_ALERTS "NodeNotReady:$NODE_NOT_READY_COUNT"
[ "$NODE_PRESSURE_COUNT" -gt 0 ] && append_csv DETECTED_ALERTS "NodePressure:$NODE_PRESSURE_COUNT"
[ "$DEPLOYMENTS_HEALTH_COUNT" -gt 0 ] && append_csv DETECTED_ALERTS "DeploymentsHealth:$DEPLOYMENTS_HEALTH_COUNT"
[ "$POD_RESTART_COUNT" -gt 0 ] && append_csv DETECTED_ALERTS "PodRestarts:$POD_RESTART_COUNT"
[ -z "$DETECTED_ALERTS" ] && DETECTED_ALERTS="none"

echo "Alert scan summary: total=$TOTAL_COUNT detected=$DETECTED_ALERTS"

HASH=$(echo "$ALERTS" | md5sum | cut -d' ' -f1)
if [ "$BACKOFF_FILTER_MODE" = "strict" ]; then
  SIMILAR_HASH="$HASH"
else
  SIMILAR_KEY=$(printf '%b\n' "$ALERTS" | grep '^\[' | tr -d '[]' | tr '\n' '|' || true)
  if [ -z "$SIMILAR_KEY" ]; then
    SIMILAR_KEY="$HASH"
  fi
  SIMILAR_HASH=$(printf '%s' "$SIMILAR_KEY" | md5sum | cut -d' ' -f1)
fi

NOW=$(date +%s)

if [ $((NOW - LAST_SENT_TS)) -lt $COOLDOWN ]; then
  echo "Alert delivery: sent=0 skipped=cooldown_active total=$TOTAL_COUNT detected=$DETECTED_ALERTS"
  build_next_notified_state 0
  save_persistent_state 0 || true
  emit_runtime_metrics
  exit 0
fi

if should_backoff_skip; then
  echo "Alert delivery: sent=0 skipped=backoff_active total=$TOTAL_COUNT detected=$DETECTED_ALERTS"
  build_next_notified_state 0
  save_persistent_state 0 || true
  emit_runtime_metrics
  exit 0
fi

TEMPLATE_MODE="${SMTP_MAIL_FORMAT:-structured}"
if [ "$TEMPLATE_MODE" = "full" ]; then
  TEMPLATE_MODE="structured"
elif [ "$TEMPLATE_MODE" = "short" ]; then
  TEMPLATE_MODE="compact"
fi
MAX_LINES="${SMTP_MAX_LINES_PER_SECTION:-5}"

if [ "$NODE_NOT_READY_COUNT" -gt 0 ] || [ "$NODE_PRESSURE_COUNT" -gt 0 ] || [ "$DEPLOYMENTS_HEALTH_COUNT" -gt 0 ] || [ "$WARNING_SURGE_COUNT" -gt 0 ] || [ "$TOTAL_COUNT" -ge 10 ]; then
  SEVERITY="CRITICAL"
elif [ "$OOM_COUNT" -gt 0 ] || [ "$EVICTED_COUNT" -gt 0 ] || [ "$PENDING_UNSCHEDULABLE_COUNT" -gt 0 ] || [ "$PROBE_FAIL_COUNT" -gt 0 ] || [ "$TOTAL_COUNT" -ge 4 ]; then
  SEVERITY="HIGH"
elif [ "$TOTAL_COUNT" -ge 2 ]; then
  SEVERITY="MEDIUM"
else
  SEVERITY="LOW"
fi

SUBJECT_PREFIX="${SMTP_SUBJECT_PREFIX:-K3S ALERT}"
PRIMARY_ALERT_TYPE=$(printf '%s' "$DETECTED_ALERTS" | awk -F',' '{print $1}' | sed 's/:.*//')
[ -z "$PRIMARY_ALERT_TYPE" ] && PRIMARY_ALERT_TYPE="General"
[ "$PRIMARY_ALERT_TYPE" = "none" ] && PRIMARY_ALERT_TYPE="General"
SUBJECT="$SUBJECT_PREFIX | $SEVERITY | $PRIMARY_ALERT_TYPE"

if [ "$TEMPLATE_MODE" = "compact" ]; then
  BODY="Summary: severity=$SEVERITY total=$TOTAL_COUNT crashloop=$CRASH_COUNT imagepull=$IMAGE_COUNT errors=$ERROR_COUNT oomKilled=$OOM_COUNT evicted=$EVICTED_COUNT pendingUnschedulable=$PENDING_UNSCHEDULABLE_COUNT probeFailures=$PROBE_FAIL_COUNT warningEventSurge=$WARNING_SURGE_COUNT nodeNotReady=$NODE_NOT_READY_COUNT nodePressure=$NODE_PRESSURE_COUNT deploymentsHealth=$DEPLOYMENTS_HEALTH_COUNT podRestarts=$POD_RESTART_COUNT\n\nTop lines:\n$(printf '%s\n' "$FULL_BODY" | head -n 8)"
else
  BODY="K3S Alert Summary\nGeneratedAt: $(date -u +%Y-%m-%dT%H:%M:%SZ)\nSeverity: $SEVERITY\nTotalIssues: $TOTAL_COUNT\n\nBreakdown:\n- CrashLoop: $CRASH_COUNT\n- ImagePull: $IMAGE_COUNT\n- Errors: $ERROR_COUNT\n- OOMKilled: $OOM_COUNT\n- Evicted: $EVICTED_COUNT\n- PendingUnschedulable: $PENDING_UNSCHEDULABLE_COUNT\n- ProbeFailures: $PROBE_FAIL_COUNT\n- WarningEventSurge: $WARNING_SURGE_COUNT\n- NodeNotReady: $NODE_NOT_READY_COUNT\n- NodePressure: $NODE_PRESSURE_COUNT\n- DeploymentsHealth: $DEPLOYMENTS_HEALTH_COUNT\n- PodRestarts: $POD_RESTART_COUNT\n"

  if [ "$CRASH_COUNT" -gt 0 ]; then
    BODY="$BODY\n\n[CrashLoop]\n$(render_section_lines "CrashLoop" "$MAX_LINES")"
  fi
  if [ "$IMAGE_COUNT" -gt 0 ]; then
    BODY="$BODY\n\n[ImagePull]\n$(render_section_lines "ImagePull" "$MAX_LINES")"
  fi
  if [ "$ERROR_COUNT" -gt 0 ]; then
    BODY="$BODY\n\n[Errors]\n$(render_section_lines "Errors" "$MAX_LINES")"
  fi
  if [ "$OOM_COUNT" -gt 0 ]; then
    BODY="$BODY\n\n[OOMKilled]\n$(render_section_lines "OOMKilled" "$MAX_LINES")"
  fi
  if [ "$EVICTED_COUNT" -gt 0 ]; then
    BODY="$BODY\n\n[Evicted]\n$(render_section_lines "Evicted" "$MAX_LINES")"
  fi
  if [ "$PENDING_UNSCHEDULABLE_COUNT" -gt 0 ]; then
    BODY="$BODY\n\n[PendingUnschedulable]\n$(render_section_lines "PendingUnschedulable" "$MAX_LINES")"
  fi
  if [ "$PROBE_FAIL_COUNT" -gt 0 ]; then
    BODY="$BODY\n\n[ProbeFailures]\n$(render_section_lines "ProbeFailures" "$MAX_LINES")"
  fi
  if [ "$WARNING_SURGE_COUNT" -gt 0 ]; then
    BODY="$BODY\n\n[WarningEventSurge]\n$(render_section_lines "WarningEventSurge" "$MAX_LINES")"
  fi
  if [ "$NODE_NOT_READY_COUNT" -gt 0 ]; then
    BODY="$BODY\n\n[NodeNotReady]\n$(render_section_lines "NodeNotReady" "$MAX_LINES")"
  fi
  if [ "$NODE_PRESSURE_COUNT" -gt 0 ]; then
    BODY="$BODY\n\n[NodePressure]\n$(render_section_lines "NodePressure" "$MAX_LINES")"
  fi
  if [ "$DEPLOYMENTS_HEALTH_COUNT" -gt 0 ]; then
    BODY="$BODY\n\n[DeploymentsHealth]\n$(render_section_lines "DeploymentsHealth" "$MAX_LINES")"
  fi
  if [ "$POD_RESTART_COUNT" -gt 0 ]; then
    BODY="$BODY\n\n[PodRestarts]\n$(render_section_lines "PodRestarts" "$MAX_LINES")"
  fi

  BODY="$BODY\n\nControls: cooldown=${COOLDOWN}s, backoff=${BACKOFF_ENABLED}/${BACKOFF_FILTER_MODE}, rateLimit=${RATE_LIMIT_ENABLED}(${RATE_LIMIT_MAX_EMAILS}/${RATE_LIMIT_PERIOD}s)"
fi

send_alert_notifications

build_next_notified_state "$SENT_ANY"
save_persistent_state "$SENT_ANY" || true

emit_runtime_metrics
