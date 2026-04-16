{{- define "k3s-alert.cronSchedule" -}}
{{- $schedule := .Values.schedule -}}
{{- if not (kindIs "map" $schedule) -}}
{{- fail "values.schedule must be a map with schedule.type and its required fields" -}}
{{- end -}}

{{- $scheduleType := default "" $schedule.type -}}
{{- $minutes := $schedule.intervalMinutes -}}
{{- $hours := $schedule.intervalHours -}}
{{- $days := $schedule.intervalDays -}}
{{- $cron := default "" $schedule.cron -}}

{{- $hasMinutes := and (hasKey $schedule "intervalMinutes") (ne $minutes nil) -}}
{{- $hasHours := and (hasKey $schedule "intervalHours") (ne $hours nil) -}}
{{- $hasDays := and (hasKey $schedule "intervalDays") (ne $days nil) -}}
{{- $hasCron := ne (trim (toString $cron)) "" -}}

{{- if eq $scheduleType "cron" -}}
{{- if not $hasCron -}}
{{- fail "values.schedule.cron is required when values.schedule.type='cron'" -}}
{{- end -}}
{{- if not (regexMatch "^\\S+(\\s+\\S+){4}$" (toString $cron)) -}}
{{- fail "values.schedule.cron must be a 5-field cron expression" -}}
{{- end -}}
{{- trim (toString $cron) -}}
{{- else if eq $scheduleType "interval" -}}

{{- $count := 0 -}}
{{- if $hasMinutes }}{{- $count = add1 $count -}}{{- end -}}
{{- if $hasHours }}{{- $count = add1 $count -}}{{- end -}}
{{- if $hasDays }}{{- $count = add1 $count -}}{{- end -}}

{{- if $hasCron -}}
{{- fail "for values.schedule.type='interval', do not set values.schedule.cron" -}}
{{- end -}}

{{- if ne $count 1 -}}
{{- fail "set exactly one of values.schedule.intervalMinutes, values.schedule.intervalHours, values.schedule.intervalDays" -}}
{{- end -}}

{{- if $hasMinutes -}}
{{- if not (regexMatch "^[1-9][0-9]*$" (toString $minutes)) -}}
{{- fail "values.schedule.intervalMinutes must be a positive integer" -}}
{{- end -}}
{{- if gt (int $minutes) 59 -}}
{{- fail "values.schedule.intervalMinutes must be between 1 and 59" -}}
{{- end -}}
{{- printf "*/%d * * * *" (int $minutes) -}}
{{- else if $hasHours -}}
{{- if not (regexMatch "^[1-9][0-9]*$" (toString $hours)) -}}
{{- fail "values.schedule.intervalHours must be a positive integer" -}}
{{- end -}}
{{- if gt (int $hours) 23 -}}
{{- fail "values.schedule.intervalHours must be between 1 and 23" -}}
{{- end -}}
{{- printf "0 */%d * * *" (int $hours) -}}
{{- else -}}
{{- if not (regexMatch "^[1-9][0-9]*$" (toString $days)) -}}
{{- fail "values.schedule.intervalDays must be a positive integer" -}}
{{- end -}}
{{- if gt (int $days) 31 -}}
{{- fail "values.schedule.intervalDays must be between 1 and 31" -}}
{{- end -}}
{{- printf "0 0 */%d * *" (int $days) -}}
{{- end -}}
{{- else -}}
{{- fail "values.schedule.type must be 'interval' or 'cron'" -}}
{{- end -}}
{{- end -}}