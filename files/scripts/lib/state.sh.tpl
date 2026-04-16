file_bytes() {
  FILE="$1"
  if [ ! -f "$FILE" ]; then
    echo 0
    return
  fi
  wc -c < "$FILE" | tr -d ' '
}

trim_file_to_max_bytes() {
  FILE="$1"
  MAX_BYTES="$2"

  if [ ! -f "$FILE" ]; then
    : > "$FILE"
  fi

  SIZE=$(file_bytes "$FILE")
  while [ "$SIZE" -gt "$MAX_BYTES" ]; do
    TMP_FILE=$(mktemp)
    tail -n +2 "$FILE" > "$TMP_FILE" 2>/dev/null || true
    mv "$TMP_FILE" "$FILE"

    NEW_SIZE=$(file_bytes "$FILE")
    if [ "$NEW_SIZE" -ge "$SIZE" ]; then
      break
    fi
    SIZE="$NEW_SIZE"
  done
}

prune_oldest_state_entries() {
  FILE="$1"
  if [ ! -s "$FILE" ]; then
    return
  fi

  TOTAL_LINES=$(wc -l < "$FILE" | tr -d ' ')
  if [ "$TOTAL_LINES" -le 1 ]; then
    : > "$FILE"
    return
  fi

  DROP_LINES=$((TOTAL_LINES / 5))
  if [ "$DROP_LINES" -lt 1 ]; then
    DROP_LINES=1
  fi

  START_LINE=$((DROP_LINES + 1))
  TMP_FILE=$(mktemp)
  tail -n +"$START_LINE" "$FILE" > "$TMP_FILE" 2>/dev/null || true
  mv "$TMP_FILE" "$FILE"
}

warn_state() {
  MSG="$1"
  log_warn "State warning: $MSG"
  STATE_PERSISTENCE_OK=0
}

safe_get_cm_key() {
  KEY="$1"
  run_kubectl get configmap "$STATE_CONFIGMAP" -n "$STATE_NAMESPACE" -o "jsonpath={.data.$KEY}"
}

ensure_state_configmap() {
  if run_kubectl get configmap "$STATE_CONFIGMAP" -n "$STATE_NAMESPACE" >/dev/null; then
    return 0
  fi

  CM_TMP=$(mktemp)
  cat > "$CM_TMP" <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: $STATE_CONFIGMAP
  namespace: $STATE_NAMESPACE
data:
  notified_keys: ""
  last_sent: "0"
  backoff_hash: ""
  backoff_level: "0"
  backoff_next_allowed: "0"
  email_rate_history: ""
EOF

  if ! run_kubectl_strict apply -f "$CM_TMP" >/dev/null 2>&1; then
    warn_state "unable to create state configmap $STATE_NAMESPACE/$STATE_CONFIGMAP"
  fi
  rm -f "$CM_TMP"
}

load_persistent_state() {
  : > "$STATE_NOTIFIED_KEYS_FILE"
  : > "$EMAIL_RATE_FILE"

  ensure_state_configmap

  NOTIFIED_RAW=$(safe_get_cm_key notified_keys)
  if [ -n "$NOTIFIED_RAW" ]; then
    printf '%s\n' "$NOTIFIED_RAW" | sed '/^$/d' | sort -u > "$STATE_NOTIFIED_KEYS_FILE"
  fi

  LAST_SENT_RAW=$(safe_get_cm_key last_sent)
  LAST_SENT_TS=$(normalize_non_negative_int "$LAST_SENT_RAW" "0")

  BACKOFF_HASH_STATE=$(safe_get_cm_key backoff_hash)
  BACKOFF_LEVEL_STATE=$(normalize_non_negative_int "$(safe_get_cm_key backoff_level)" "0")
  BACKOFF_NEXT_ALLOWED_STATE=$(normalize_non_negative_int "$(safe_get_cm_key backoff_next_allowed)" "0")

  EMAIL_RATE_RAW=$(safe_get_cm_key email_rate_history)
  if [ -n "$EMAIL_RATE_RAW" ]; then
    printf '%s\n' "$EMAIL_RATE_RAW" | sed '/^$/d' | tail -n "$MAX_EMAIL_RATE_LINES" > "$EMAIL_RATE_FILE"
  fi

  NOTIFIED_COUNT=$(wc -l < "$STATE_NOTIFIED_KEYS_FILE" | tr -d ' ')
  RATE_COUNT=$(wc -l < "$EMAIL_RATE_FILE" | tr -d ' ')
  log_debug "State loaded: notifiedKeys=$NOTIFIED_COUNT lastSent=$LAST_SENT_TS backoffLevel=$BACKOFF_LEVEL_STATE rateHistory=$RATE_COUNT"
}

build_next_notified_state() {
  SENT_FLAG="$1"

  sort -u "$STATE_NOTIFIED_KEYS_FILE" > "${STATE_NOTIFIED_KEYS_FILE}.sorted" 2>/dev/null || true
  sort -u "$CURRENT_ACTIVE_KEYS_FILE" > "${CURRENT_ACTIVE_KEYS_FILE}.sorted" 2>/dev/null || true

  comm -12 "${STATE_NOTIFIED_KEYS_FILE}.sorted" "${CURRENT_ACTIVE_KEYS_FILE}.sorted" > "$NEXT_NOTIFIED_KEYS_FILE" 2>/dev/null || true

  if [ "$SENT_FLAG" -eq 1 ] && [ -s "$NEW_ALERT_KEYS_FILE" ]; then
    cat "$NEW_ALERT_KEYS_FILE" >> "$NEXT_NOTIFIED_KEYS_FILE"
  fi

  sort -u "$NEXT_NOTIFIED_KEYS_FILE" -o "$NEXT_NOTIFIED_KEYS_FILE" 2>/dev/null || true
  tail -n "$MAX_NOTIFIED_KEYS" "$NEXT_NOTIFIED_KEYS_FILE" > "${NEXT_NOTIFIED_KEYS_FILE}.trim" 2>/dev/null || true
  mv "${NEXT_NOTIFIED_KEYS_FILE}.trim" "$NEXT_NOTIFIED_KEYS_FILE"
}

update_backoff_state_after_send() {
  [ "$BACKOFF_ENABLED" != "true" ] && return 0

  if [ "$BACKOFF_HASH_STATE" = "$SIMILAR_HASH" ]; then
    NEXT_LEVEL=$((BACKOFF_LEVEL_STATE + 1))
  else
    NEXT_LEVEL=0
  fi

  DELAY=$(next_backoff_delay "$NEXT_LEVEL")
  BACKOFF_HASH_STATE="$SIMILAR_HASH"
  BACKOFF_LEVEL_STATE="$NEXT_LEVEL"
  BACKOFF_NEXT_ALLOWED_STATE=$((NOW + DELAY))
}

save_persistent_state() {
  SENT_FLAG="$1"

  if [ "$SENT_FLAG" -eq 1 ]; then
    LAST_SENT_TS="$NOW"
  fi

  if [ ! -f "$EMAIL_RATE_FILE" ]; then
    : > "$EMAIL_RATE_FILE"
  fi
  tail -n "$MAX_EMAIL_RATE_LINES" "$EMAIL_RATE_FILE" > "${EMAIL_RATE_FILE}.trim" 2>/dev/null || true
  mv "${EMAIL_RATE_FILE}.trim" "$EMAIL_RATE_FILE"

  trim_file_to_max_bytes "$NEXT_NOTIFIED_KEYS_FILE" "$MAX_NOTIFIED_KEYS_BYTES"
  trim_file_to_max_bytes "$EMAIL_RATE_FILE" "$MAX_EMAIL_RATE_BYTES"

  PRUNE_ATTEMPT=0
  while [ "$PRUNE_ATTEMPT" -le "$MAX_STATE_SIZE_PRUNE_ATTEMPTS" ]; do
    CM_RENDER_FILE=$(mktemp)
    if ! run_kubectl_strict create configmap "$STATE_CONFIGMAP" -n "$STATE_NAMESPACE" \
      --from-file=notified_keys="$NEXT_NOTIFIED_KEYS_FILE" \
      --from-literal=last_sent="$LAST_SENT_TS" \
      --from-literal=backoff_hash="$BACKOFF_HASH_STATE" \
      --from-literal=backoff_level="$BACKOFF_LEVEL_STATE" \
      --from-literal=backoff_next_allowed="$BACKOFF_NEXT_ALLOWED_STATE" \
      --from-file=email_rate_history="$EMAIL_RATE_FILE" \
      --dry-run=client -o yaml > "$CM_RENDER_FILE" 2>/dev/null; then
      warn_state "unable to render state configmap payload"
      rm -f "$CM_RENDER_FILE"
      return 1
    fi

    CM_SIZE_BYTES=$(file_bytes "$CM_RENDER_FILE")
    if [ "$CM_SIZE_BYTES" -le "$MAX_STATE_CONFIGMAP_BYTES" ]; then
      if ! run_kubectl_strict apply -f "$CM_RENDER_FILE" >/dev/null 2>&1; then
        warn_state "unable to persist state to $STATE_NAMESPACE/$STATE_CONFIGMAP"
        rm -f "$CM_RENDER_FILE"
        return 1
      fi

      rm -f "$CM_RENDER_FILE"
      return 0
    fi

    rm -f "$CM_RENDER_FILE"
    PRUNE_ATTEMPT=$((PRUNE_ATTEMPT + 1))
    log_warn "State info: rendered payload ${CM_SIZE_BYTES}B exceeds limit ${MAX_STATE_CONFIGMAP_BYTES}B; pruning oldest persisted entries (attempt $PRUNE_ATTEMPT/$MAX_STATE_SIZE_PRUNE_ATTEMPTS)"

    prune_oldest_state_entries "$NEXT_NOTIFIED_KEYS_FILE"
    prune_oldest_state_entries "$EMAIL_RATE_FILE"
    trim_file_to_max_bytes "$NEXT_NOTIFIED_KEYS_FILE" "$MAX_NOTIFIED_KEYS_BYTES"
    trim_file_to_max_bytes "$EMAIL_RATE_FILE" "$MAX_EMAIL_RATE_BYTES"
  done

  warn_state "state payload exceeded byte budget even after pruning"
  return 1
}
