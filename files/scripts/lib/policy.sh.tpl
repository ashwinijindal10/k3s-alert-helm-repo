normalize_for_fingerprint() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[0-9][0-9]*/#/g; s/[[:space:]][[:space:]]*/ /g; s/^ //; s/ $//'
}

fingerprint_line() {
  SECTION="$1"
  LINE="$2"
  NORMALIZED_LINE=$(normalize_for_fingerprint "$LINE")
  printf '%s|%s' "$SECTION" "$NORMALIZED_LINE" | md5sum | cut -d' ' -f1
}

filter_new_alerts() {
  FILTERED_ALERTS=""
  CURRENT_SECTION=""
  LAST_OUTPUT_SECTION=""
  ALERT_SCAN_FILE=$(mktemp)

  : > "$CURRENT_ACTIVE_KEYS_FILE"
  : > "$NEW_ALERT_KEYS_FILE"
  printf '%b\n' "$ALERTS" | sed '/^$/d' > "$ALERT_SCAN_FILE"

  while IFS= read -r line; do
    [ -z "$line" ] && continue
    case "$line" in
      \[*\])
        CURRENT_SECTION=$(printf '%s' "$line" | tr -d '[]')
        LAST_OUTPUT_SECTION=""
        ;;
      *)
        [ -z "$CURRENT_SECTION" ] && continue
        KEY=$(fingerprint_line "$CURRENT_SECTION" "$line")
        echo "$KEY" >> "$CURRENT_ACTIVE_KEYS_FILE"

        if grep -Fxq "$KEY" "$STATE_NOTIFIED_KEYS_FILE"; then
          continue
        fi

        if [ "$LAST_OUTPUT_SECTION" != "$CURRENT_SECTION" ]; then
          FILTERED_ALERTS="$FILTERED_ALERTS\n[$CURRENT_SECTION]"
          LAST_OUTPUT_SECTION="$CURRENT_SECTION"
        fi
        FILTERED_ALERTS="$FILTERED_ALERTS\n$line"
        echo "$KEY" >> "$NEW_ALERT_KEYS_FILE"
        ;;
    esac
  done < "$ALERT_SCAN_FILE"
  rm -f "$ALERT_SCAN_FILE"

  ALERTS=$(printf '%b\n' "$FILTERED_ALERTS" | sed '/^$/d')
}

should_backoff_skip() {
  [ "$BACKOFF_ENABLED" != "true" ] && return 1
  [ -z "$BACKOFF_HASH_STATE" ] && return 1
  if [ "$BACKOFF_HASH_STATE" = "$SIMILAR_HASH" ] && [ "$NOW" -lt "$BACKOFF_NEXT_ALLOWED_STATE" ]; then
    return 0
  fi
  return 1
}

next_backoff_delay() {
  CURRENT_LEVEL=$1
  VALUE=$BACKOFF_BASE_DELAY
  I=0
  while [ "$I" -lt "$CURRENT_LEVEL" ]; do
    VALUE=$((VALUE * BACKOFF_FACTOR))
    if [ "$VALUE" -ge "$BACKOFF_MAX_DELAY" ]; then
      VALUE=$BACKOFF_MAX_DELAY
      break
    fi
    I=$((I + 1))
  done
  echo "$VALUE"
}

can_send_email() {
  if [ "$RATE_LIMIT_ENABLED" != "true" ]; then
    return 0
  fi

  NOW_TS=$(date +%s)
  WINDOW_START=$((NOW_TS - RATE_LIMIT_PERIOD))

  awk -v min="$WINDOW_START" '$1 >= min { print $1 }' "$EMAIL_RATE_FILE" > "${EMAIL_RATE_FILE}.tmp" || true
  mv "${EMAIL_RATE_FILE}.tmp" "$EMAIL_RATE_FILE"

  SENT_COUNT=$(wc -l < "$EMAIL_RATE_FILE" | tr -d ' ')
  if [ "$SENT_COUNT" -ge "$RATE_LIMIT_MAX_EMAILS" ]; then
    return 1
  fi

  echo "$NOW_TS" >> "$EMAIL_RATE_FILE"
  return 0
}
