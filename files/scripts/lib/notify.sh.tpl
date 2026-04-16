mark_restart_threshold_notified() {
  if [ -z "${RESTART_ALERT_TARGETS:-}" ]; then
    return 0
  fi

  printf '%b\n' "$RESTART_ALERT_TARGETS" | while IFS='|' read -r ns pod; do
    [ -z "$ns" ] && continue
    [ -z "$pod" ] && continue
    run_kubectl annotate pod "$pod" -n "$ns" k3s-alert/restart-threshold-notified=true --overwrite >/dev/null || true
  done
}

json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; :a;N;$!ba;s/\n/\\n/g; s/\r/\\r/g'
}

send_alert_notifications() {
  SENT_ANY=0
  SENT_CHANNELS=""
  SKIPPED_REASONS=""

  {{- if .Values.channels.email.enabled }}
  if [ -n "${SMTP_HOST:-}" ] && [ -n "${SMTP_TO:-}" ] && [ -n "${SMTP_USERNAME:-}" ] && [ -n "${SMTP_PASSWORD:-}" ]; then
    RECIPIENTS=$(printf '%s' "$SMTP_TO" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | sed '/^$/d')
    if [ -z "$RECIPIENTS" ]; then
      log_warn "No valid SMTP recipients found"
      append_csv SKIPPED_REASONS "email_no_recipients"
    else
      set --
      for recipient in $RECIPIENTS; do
        set -- "$@" --mail-rcpt "$recipient"
      done

      if ! can_send_email; then
        log_warn "Email rate limit active: max $RATE_LIMIT_MAX_EMAILS emails per $RATE_LIMIT_PERIOD seconds"
        append_csv SKIPPED_REASONS "email_rate_limited"
      else
        if [ -n "${SMTP_LOGIN_OPTIONS:-}" ]; then
          printf 'Subject: %s\n\n%b' "$SUBJECT" "$BODY" | curl -sS --connect-timeout 10 --max-time 20 --url "smtp://$SMTP_HOST:$SMTP_PORT" \
            --ssl-reqd \
            --mail-from "$SMTP_FROM" \
            "$@" \
            --login-options "$SMTP_LOGIN_OPTIONS" \
            --upload-file - \
            --user "$SMTP_USERNAME:$SMTP_PASSWORD" >/dev/null
        else
          printf 'Subject: %s\n\n%b' "$SUBJECT" "$BODY" | curl -sS --connect-timeout 10 --max-time 20 --url "smtp://$SMTP_HOST:$SMTP_PORT" \
            --ssl-reqd \
            --mail-from "$SMTP_FROM" \
            "$@" \
            --upload-file - \
            --user "$SMTP_USERNAME:$SMTP_PASSWORD" >/dev/null
        fi
        log_info "Email alert sent"
        SENT_ANY=1
        append_csv SENT_CHANNELS "email"
      fi
    fi
  else
    log_warn "Email channel enabled but required SMTP vars are missing"
    append_csv SKIPPED_REASONS "email_missing_config"
  fi
  {{- end }}

  {{- if .Values.channels.webhook.enabled }}
  if [ -n "${WEBHOOK_URL:-}" ]; then
    PAYLOAD=$(printf '{"subject":"%s","message":"%s"}' "$(json_escape "$SUBJECT")" "$(json_escape "$BODY")")
    curl -sS --connect-timeout 10 --max-time 20 -X POST "$WEBHOOK_URL" \
      -H "Content-Type: application/json" \
      -d "$PAYLOAD" >/dev/null
    log_info "Webhook alert sent"
    SENT_ANY=1
    append_csv SENT_CHANNELS "webhook"
  else
    log_warn "Webhook channel enabled but WEBHOOK_URL is empty"
    append_csv SKIPPED_REASONS "webhook_missing_url"
  fi
  {{- end }}

  if [ "$SENT_ANY" -eq 1 ]; then
    [ -z "$SENT_CHANNELS" ] && SENT_CHANNELS="unknown"
    [ -z "$SKIPPED_REASONS" ] && SKIPPED_REASONS="none"
    log_info "Alert delivery: sent=1 channels=$SENT_CHANNELS skipped=$SKIPPED_REASONS total=$TOTAL_COUNT detected=$DETECTED_ALERTS"

    mark_restart_threshold_notified
    update_backoff_state_after_send
  else
    [ -z "$SKIPPED_REASONS" ] && SKIPPED_REASONS="no_channel_sent"
    log_warn "Alert delivery: sent=0 skipped=$SKIPPED_REASONS total=$TOTAL_COUNT detected=$DETECTED_ALERTS"
  fi
}
