add_alert_section() {
  SECTION_NAME="$1"
  SECTION_BODY="$2"
  [ -z "$SECTION_BODY" ] && return 0
  ALERTS="$ALERTS\n[$SECTION_NAME]\n$SECTION_BODY"
}

run_app_checks() {
  {{- if .Values.alerts.podCrashLoop }}
  CRASH=$(echo "$PODS" | grep -E "CrashLoopBackOff" || true)
  add_alert_section "CrashLoop" "$CRASH"
  {{- end }}

  {{- if .Values.alerts.podImagePullError }}
  IMG=$(echo "$PODS" | grep -E "ImagePullBackOff|ErrImagePull" || true)
  add_alert_section "ImagePull" "$IMG"
  {{- end }}

  {{- if .Values.alerts.podError }}
  ERR=$(echo "$PODS" | grep -E "Error|Failed" || true)
  add_alert_section "Errors" "$ERR"
  {{- end }}

  {{- if .Values.alerts.podOOMKilled }}
  OOM=$(run_kubectl get pods -A -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{" "}{range .status.containerStatuses[*]}{.name}{":"}{.state.terminated.reason}{":"}{.lastState.terminated.reason}{";"}{end}{"\n"}{end}' | grep -E 'OOMKilled' || true)
  OOM=$(filter_excluded_namespaces "$OOM")
  add_alert_section "OOMKilled" "$OOM"
  {{- end }}

  {{- if .Values.alerts.podEvicted }}
  EVICTED=$(echo "$PODS" | grep -E "[[:space:]]Evicted[[:space:]]" || true)
  add_alert_section "Evicted" "$EVICTED"
  {{- end }}

  {{- if .Values.alerts.pendingUnschedulable }}
  UNSCHEDULABLE=$(run_kubectl get pods -A --field-selector=status.phase=Pending -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{"|"}{range .status.conditions[*]}{.type}{"="}{.status}{":"}{.reason}{";"}{end}{"\n"}{end}' | awk -F'|' '$2 ~ /PodScheduled=False:Unschedulable/ {print $1" "$2}' || true)
  UNSCHEDULABLE=$(filter_excluded_namespaces "$UNSCHEDULABLE")
  UNSCHEDULABLE_COUNT=$(count_non_empty_lines "$UNSCHEDULABLE")
  if [ "$UNSCHEDULABLE_COUNT" -ge "$PENDING_UNSCHEDULABLE_MIN_PODS" ] && [ "$UNSCHEDULABLE_COUNT" -gt 0 ]; then
    add_alert_section "PendingUnschedulable" "$UNSCHEDULABLE"
  fi
  {{- end }}

  {{- if .Values.alerts.probeFailures }}
  PROBE_FAILS=$(echo "$WARNING_EVENTS" | grep -Ei 'Readiness probe failed|Liveness probe failed' || true)
  add_alert_section "ProbeFailures" "$PROBE_FAILS"
  {{- end }}

  {{- if .Values.alerts.warningEventsSurge }}
  WARN_COUNT=$(count_non_empty_lines "$WARNING_EVENTS")
  if [ "$WARNING_EVENTS_SURGE" = "true" ] && [ "$WARN_COUNT" -ge "$WARNING_EVENTS_SURGE_THRESHOLD" ]; then
    add_alert_section "WarningEventSurge" "$(printf '%s\n' "$WARNING_EVENTS" | tail -n 20)"
  fi
  {{- end }}

  if [ "$POD_RESTART_THRESHOLD" -ge 0 ]; then
    RESTART_CANDIDATES=$(echo "$PODS" | awk -v threshold="$POD_RESTART_THRESHOLD" '
      {
        ns=$1
        pod=$2
        status=$4
        restarts=$5
        gsub(/[^0-9]/, "", restarts)
        if (restarts == "") {
          restarts=0
        }
        if ((restarts + 0) > threshold) {
          print ns" "pod" "status" "restarts
        }
      }
    ' || true)

    if [ -n "$RESTART_CANDIDATES" ]; then
      NEW_RESTART_ALERTS=""
      RESTART_SCAN_FILE=$(mktemp)
      printf '%s\n' "$RESTART_CANDIDATES" > "$RESTART_SCAN_FILE"
      while IFS= read -r candidate; do
        [ -z "$candidate" ] && continue
        NS=$(echo "$candidate" | awk '{print $1}')
        POD=$(echo "$candidate" | awk '{print $2}')
        NOTIFIED=$(run_kubectl get pod "$POD" -n "$NS" -o jsonpath="{.metadata.annotations['k3s-alert/restart-threshold-notified']}")
        if [ "$NOTIFIED" = "true" ]; then
          continue
        fi
        if [ -z "$NEW_RESTART_ALERTS" ]; then
          NEW_RESTART_ALERTS="$candidate"
        else
          NEW_RESTART_ALERTS="$NEW_RESTART_ALERTS\n$candidate"
        fi

        if [ -z "$RESTART_ALERT_TARGETS" ]; then
          RESTART_ALERT_TARGETS="$NS|$POD"
        else
          RESTART_ALERT_TARGETS="$RESTART_ALERT_TARGETS\n$NS|$POD"
        fi
      done < "$RESTART_SCAN_FILE"
      rm -f "$RESTART_SCAN_FILE"

      add_alert_section "PodRestarts" "$NEW_RESTART_ALERTS"
    fi
  fi
}

run_cluster_checks() {
  {{- if .Values.alerts.nodeNotReady }}
  NODE_NOT_READY=$(echo "$NODES_STATUS" | awk -F'|' '$2 !~ /Ready=True/ {print $1"|"$2}' || true)
  add_alert_section "NodeNotReady" "$NODE_NOT_READY"
  {{- end }}

  {{- if .Values.alerts.nodePressure }}
  NODE_PRESSURE=$(echo "$NODES_STATUS" | awk -F'|' '
    {
      if ($2 ~ /MemoryPressure=True/ || $2 ~ /DiskPressure=True/ || $2 ~ /PIDPressure=True/) {
        print $0
      }
    }
  ' || true)
  add_alert_section "NodePressure" "$NODE_PRESSURE"
  {{- end }}

  {{- if .Values.alerts.deploymentsHealthCheck }}
  if [ -n "$DEPLOYMENT_HEALTH_TARGETS" ]; then
    DEPLOYMENTS_ALL=$(run_kubectl get deployments -A --no-headers)
    DEPLOYMENTS_HEALTH_REPORT=$(printf '%s' "$DEPLOYMENT_HEALTH_TARGETS" | tr ',' '\n' | sed '/^$/d' | while IFS= read -r target; do
      NS=$(echo "$target" | cut -d'/' -f1)
      DEPLOYMENT_NAME=$(echo "$target" | cut -d'/' -f2-)
      [ -z "$NS" ] && continue
      [ -z "$DEPLOYMENT_NAME" ] && continue

      MATCHING_DEPLOYMENT=$(echo "$DEPLOYMENTS_ALL" | awk -v ns="$NS" -v dep="$DEPLOYMENT_NAME" '$1 == ns && $2 == dep {print; exit}')
      if [ -z "$MATCHING_DEPLOYMENT" ]; then
        if [ "$DEPLOYMENT_HEALTH_INCLUDE_MISSING_TARGETS" = "true" ]; then
          echo "$NS/$DEPLOYMENT_NAME missing"
        fi
        continue
      fi

      READY_COLUMN=$(echo "$MATCHING_DEPLOYMENT" | awk '{print $3}')
      READY_REPLICAS=$(echo "$READY_COLUMN" | cut -d'/' -f1)
      DESIRED_REPLICAS=$(echo "$READY_COLUMN" | cut -d'/' -f2)
      READY_REPLICAS=$(normalize_non_negative_int "$READY_REPLICAS" "0")
      DESIRED_REPLICAS=$(normalize_non_negative_int "$DESIRED_REPLICAS" "0")

      UNHEALTHY=0
      REASON=""
      if [ "$DESIRED_REPLICAS" -eq 0 ] && [ "$DEPLOYMENT_HEALTH_INCLUDE_ZERO_DESIRED" = "true" ]; then
        UNHEALTHY=1
        REASON="desired=0"
      elif [ "$DESIRED_REPLICAS" -gt 0 ]; then
        READY_PERCENT=$((READY_REPLICAS * 100 / DESIRED_REPLICAS))
        if [ "$READY_PERCENT" -lt "$DEPLOYMENT_HEALTH_MIN_READY_PERCENT" ]; then
          UNHEALTHY=1
          REASON="ready=${READY_REPLICAS}/${DESIRED_REPLICAS}(${READY_PERCENT}%)"
        fi
      fi

      if [ "$UNHEALTHY" -eq 1 ]; then
        echo "$NS/$DEPLOYMENT_NAME $REASON"
      fi
    done)

    DEPLOYMENTS_HEALTH_REPORT=$(printf '%s\n' "$DEPLOYMENTS_HEALTH_REPORT" | sed '/^$/d' | head -n "$DEPLOYMENT_HEALTH_MAX_REPORTED_LINES")
    add_alert_section "DeploymentsHealth" "$DEPLOYMENTS_HEALTH_REPORT"
  fi
  {{- end }}
}
