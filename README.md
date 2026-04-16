# k3s-alert Helm Chart

Lightweight CronJob-based alerting for pod and node failures in k3s/k8s.

## What it monitors

- Pod failures:
  - CrashLoopBackOff
  - ImagePullBackOff / ErrImagePull
  - Error / Failed
  - OOMKilled (from container terminated/last terminated reason)
  - Evicted
  - Pending + Unschedulable pods
  - Probe failures from Warning events (Readiness/Liveness)
  - Restart count over configured threshold (`alerts.podRestartThreshold`)
- Node failures:
  - NotReady
  - Pressure conditions (MemoryPressure, DiskPressure, PIDPressure)
- Cluster critical component failures:
  - kube-system critical deployments below desired ready replicas

Restart-threshold alerts are one-time per pod after threshold crossing and are tracked with pod annotation `k3s-alert/restart-threshold-notified=true`.

This chart is intentionally simple and resource-friendly:

- Polling model (no long-running watch loops)
- Single CronJob run per interval
- Persistent dedupe state in ConfigMap (`k3s-alert-state`)
- Persistent cooldown/backoff/rate-limit state in ConfigMap (`k3s-alert-state`)
- Very low default CPU/memory requests

Script source layout:

- Main runtime script is maintained in `files/scripts/check.sh.tpl`
- State persistence and guards are in `files/scripts/lib/state.sh.tpl`
- Alert policy logic (dedupe/backoff/rate-limit) is in `files/scripts/lib/policy.sh.tpl`
- Detection logic is in `files/scripts/lib/detection.sh.tpl`
- Notification delivery logic is in `files/scripts/lib/notify.sh.tpl`
- It is rendered into ConfigMap `k3s-alert-script` as `check.sh`

Low-overhead defaults for stability:

- Warning-event surge detection is disabled by default (`alerts.warningEventsSurge: false`)
- Warning events scan is capped to latest 200 warning lines per run
- Pending-unschedulable alert can be threshold-gated by pod count (`alerts.pendingUnschedulableMinPods`)
- Each run emits a self-metrics log line (`Run metrics`) with duration, API calls, and scanned row counts

## Notification channels

Supported channels:

- Email (SMTP)
- Generic webhook (JSON POST)

Payload is plain-text summary for both channels.

## Secret input modes

`secrets.source` supports:

- `secret`: Read SMTP credentials from an existing Kubernetes Secret.
- `externalSecret`: Same as `secret`; secret is expected to be created by ExternalSecret controller.

For SMTP authentication, you can also bypass secrets and pass username/password directly in values by using `smtp.secretType: plain`.

By default, curl auto-negotiates SMTP auth. If your provider needs explicit auth mode, set `smtp.loginOptions` (example: `AUTH=PLAIN`).

For email body template, use:

- `smtp.mailFormat: structured` (default, recommended)
- `smtp.mailFormat: compact` (short digest)

Backward compatible aliases are also supported:

- `full` -> `structured`
- `short` -> `compact`

`smtp.to` supports both:

- Comma-separated string: `"a@example.com,b@example.com"`
- YAML list:
  - `a@example.com`
  - `b@example.com`

## Install

### Prerequisites

- A running k3s/k8s cluster
- `kubectl` configured for the target cluster
- `helm` installed
- SMTP credentials available (Secret/ExternalSecret or plain values)

### Option A: Install from published Helm repository

1. Add and update repository.

```bash
helm repo add k3s-alert https://ashwinijindal10.github.io/k3s-alert-helm-repo/charts
helm repo update
```

2. Create your override values file (example: `k3s-alert-values.yaml`).

```yaml
channels:
  email:
    enabled: true
  webhook:
    enabled: false

smtp:
  to: "you@example.com,team@example.com"
```

3. Install or upgrade.

```bash
helm upgrade --install k3s-alert k3s-alert/k3s-alert \
  -n kube-system  \
  -f k3s-alert-values.yaml
```

### Option B: Install from local source

1. Go to this chart repository root (the folder containing `Chart.yaml`).

```bash
cd /path/to/k3s-alert-helm-repo
```

2. Create your override values file (example: `k3s-alert-values.yaml`) and choose credential mode.

Secret/ExternalSecret mode:

```yaml
smtp:
  secretType: externalSecret

secrets:
  source: externalSecret
  name: ext-secrets
  smtpUsernameKey: username
  smtpPasswordKey: password
```

Plain mode:

```yaml
smtp:
  secretType: plain
  username: "your-smtp-username"
  password: "your-smtp-password"
```

3. Install or upgrade.

```bash
helm upgrade --install k3s-alert . \
  -n kube-system --create-namespace \
  -f k3s-alert-values.yaml
```

### Post-install checks

```bash
kubectl get cronjob -n kube-system k3s-alert
kubectl get jobs -n kube-system --sort-by=.metadata.creationTimestamp
kubectl get pods -n kube-system -l job-name
kubectl logs -n kube-system job/<latest-job-name>
```

## Rebuild and publish chart (after changes)

Automatic mode (recommended):

- A GitHub Actions workflow (`.github/workflows/release-chart.yml`) runs on every push to `main`.
- It automatically bumps chart patch version in `Chart.yaml`, packages into `docs/charts`, rebuilds `docs/charts/index.yaml`, and commits artifacts back.
- Result: new chart version becomes available automatically from the same Helm repo URL.

Manual fallback:

Run these steps when `Chart.yaml`, `templates/`, or chart behavior changes.

1. Bump `version` in `Chart.yaml` for each release.
2. Package chart into `docs/charts`.
3. Rebuild chart index with the same repository base URL.
4. Commit and push.

```bash
# from repo root
helm lint .
helm package . --destination docs/charts
helm repo index docs/charts \
  --url https://ashwinijindal10.github.io/k3s-alert-helm-repo/charts

git add Chart.yaml values.yaml docs/charts/
git commit -m "chore(release): package chart and update index"
git push origin main
```

Consumer side refresh after publish:

```bash
helm repo update
helm search repo k3s-alert/k3s-alert --versions
```

## Default values summary

- `schedule`: `*/2 * * * *`
- `channels.email.enabled`: `true`
- `channels.webhook.enabled`: `false`
- `cooldownSeconds`: `60`
- `logLevel`: `info` (`debug`, `info`, `warning`, `error`)
- `smtp.mailFormat`: `structured`
- `smtp.subjectPrefix`: `K3S ALERT`
- `smtp.maxLinesPerSection`: `5`
- `backoff.enabled`: `true`
- `backoff.filterMode`: `strict`
- `backoff.baseDelaySeconds`: `120`
- `backoff.factor`: `2`
- `backoff.maxDelaySeconds`: `36000`
- `rateLimit.enabled`: `true`
- `rateLimit.periodSeconds`: `900`
- `rateLimit.maxEmails`: `5`
- `alerts.podRestartThreshold`: `2` (`-1` disables restart-threshold alerts)
- `alerts.podOOMKilled`: `true`
- `alerts.podEvicted`: `true`
- `alerts.pendingUnschedulable`: `true`
- `alerts.pendingUnschedulableMinPods`: `1`
- `alerts.probeFailures`: `true`
- `alerts.warningEventsSurge`: `false`
- `alerts.warningEventsSurgeThreshold`: `25`
- `alerts.deploymentsHealthCheck`: `true`
- `deploymentsHealthCheck.targets`: `kube-system/coredns`, `kube-system/metrics-server`, `kube-system/local-path-provisioner`
- `deploymentsHealthCheck.settings.minReadyPercent`: `100`
- `deploymentsHealthCheck.settings.includeZeroDesired`: `true`
- `deploymentsHealthCheck.settings.maxReportedLines`: `10`
- `deploymentsHealthCheck.settings.includeMissingTargets`: `true`
- `cronJob.concurrencyPolicy`: `Forbid`
- `filters.excludeNamespaces`: `kube-system`, `kube-public`

## Configuration Parameter Details

### Alert switches

### Logging

- `logLevel`
  - Controls runtime log verbosity for `check.sh`.
  - Supported values: `debug`, `info`, `warning`, `error`.
  - Default `info` gives lifecycle and delivery summaries.

- `alerts.podCrashLoop`
  - Detects `CrashLoopBackOff` pod states.
  - Keep enabled in most environments.

- `alerts.podImagePullError`
  - Detects `ImagePullBackOff` and `ErrImagePull`.
  - Useful for registry/auth/image tag issues.

- `alerts.podError`
  - Detects generic pod error/failure states from pod listings.
  - May be broad; combine with cooldown/backoff to reduce noise.

- `alerts.podOOMKilled`
  - Detects OOM via container terminated/last-terminated reason.
  - High-signal for app stability.

- `alerts.podEvicted`
  - Detects evicted pods, commonly from memory or disk pressure.
  - Strong cluster-capacity indicator.

- `alerts.pendingUnschedulable`
  - Detects pending pods with unschedulable condition.
  - Pair with `alerts.pendingUnschedulableMinPods` to avoid single-pod noise.

- `alerts.probeFailures`
  - Detects readiness/liveness probe failures from warning events.
  - Good early indicator of app degradation.

- `alerts.warningEventsSurge`
  - Detects warning-event storms when enabled.
  - Keep disabled by default in low-noise setups.

- `alerts.nodeNotReady`
  - Detects nodes not reporting `Ready=True`.
  - Critical cluster-health signal.

- `alerts.nodePressure`
  - Detects memory/disk/PID pressure node conditions.
  - Critical for preventing cascading failures.

- `alerts.deploymentsHealthCheck`
  - Enables deployment health checks using `deploymentsHealthCheck.targets`.
  - Works for any namespace, not only `kube-system`.

### Deployment health configuration

- `deploymentsHealthCheck.targets`
  - List of `namespace/name` deployment targets to monitor.
  - Example: `kube-system/coredns`.
  - Keep this list focused on critical components and business-critical deployments.

- `deploymentsHealthCheck.settings.minReadyPercent`
  - Minimum ready percentage required for a target deployment.
  - Typical values:
    - `100`: strict mode (all desired replicas must be ready).
    - `50-99`: tolerant mode for non-critical workloads.

- `deploymentsHealthCheck.settings.includeZeroDesired`
  - If `true`, deployments with desired replicas `0` are reported as unhealthy.
  - Set `false` if you intentionally scale some targets to zero.

- `deploymentsHealthCheck.settings.maxReportedLines`
  - Caps lines included in alert body for deployment-health findings.
  - Prevents oversized notifications and keeps messages readable.

- `deploymentsHealthCheck.settings.includeMissingTargets`
  - If `true`, missing target deployments are reported.
  - Recommended `true` for critical control-plane and core infra checks.

### Noise and load control

- Persistent dedupe (default behavior)
  - Active findings are fingerprinted and stored in `k3s-alert-state`.
  - The same active finding is alerted once, then suppressed while it remains active.
  - If a finding resolves and later reappears, it alerts again.

- `cooldownSeconds`
  - Minimum delay between sends for any alert payload.

- `backoff.*`
  - Exponential suppression for repeated similar alerts.
  - State is persisted across CronJob runs, so `filterMode: strict` remains effective.

- `rateLimit.*`
  - Hard cap on outbound emails per time window.
  - State is persisted across CronJob runs.

- `schedule`
  - Poll interval for the CronJob.
  - `*/2 * * * *` is a good default for low overhead.
  - Increase interval for very large clusters if API pressure is a concern.

## Configuration examples

### 1) Secret mode (all sensitive fields from secret)

```yaml
channels:
  email:
    enabled: true
  webhook:
    enabled: true

secrets:
  source: secret
  name: ext-secrets
  smtpUsernameKey: username
  smtpPasswordKey: password
```

Expected secret data keys:

- `username`
- `password`

### 2) ExternalSecret mode

```yaml
secrets:
  source: externalSecret
  name: ext-secrets
  smtpUsernameKey: username
  smtpPasswordKey: password
```

Use this when `ext-secrets` is managed outside this chart by an ExternalSecret.


### 3) Plain SMTP auth mode (no secret for username/password)

```yaml
channels:
  email:
    enabled: true
  webhook:
    enabled: false

smtp:
  secretType: plain
  mailFormat: compact
  subjectPrefix: "K3S ALERT"
  maxLinesPerSection: 5
  host: "smtp.email.ap-hyderabad-1.oci.oraclecloud.com"
  port: "587"
  from: "noreply@example.com"
  to: "ops-team@example.com,team-alerts@example.com"
  username: "your-smtp-username"
  password: "your-smtp-password"
  loginOptions: "AUTH=PLAIN"
```

List style:

```yaml
smtp:
  to:
    - "ops-team@example.com"
    - "team-alerts@example.com"
```

### 4) Webhook mode (optional)

```yaml
channels:
  email:
    enabled: false
  webhook:
    enabled: true

webhook:
  url: "https://example.org/alert-endpoint"
```

### 5) Email rate limiting

```yaml
rateLimit:
  enabled: true
  periodSeconds: 900
  maxEmails: 3
```

This limits outgoing emails to `maxEmails` within `periodSeconds`.

### 6) Exponential backoff for repeated similar alerts

```yaml
backoff:
  enabled: true
  filterMode: basic
  baseDelaySeconds: 120
  factor: 2
  maxDelaySeconds: 36000
```

For repeated similar alerts, next send delay grows exponentially and is capped by `maxDelaySeconds`.

Filter mode options:

- `basic`: Backoff groups alerts by section type (`[CrashLoop]`, `[ImagePull]`, `[Errors]`, `[NodeNotReady]`, `[NodePressure]`).
- `strict`: Backoff matches full alert content (namespace/pod/error lines). Even small line changes are treated as new alerts.

Real example difference:

Run 1 alert content:

```text
[CrashLoop]
default payment-api-7c9c57cf54-4x7jp 0/1 CrashLoopBackOff 8 (45s ago) 11m

[ImagePull]
default report-worker-6c7d9f6d8b-zj5rn 0/1 ImagePullBackOff 5 (30s ago) 9m
```

Run 2 alert content (same error types, different pod names):

```text
[CrashLoop]
default payment-api-7c9c57cf54-ml2kn 0/1 CrashLoopBackOff 3 (20s ago) 4m

[ImagePull]
default report-worker-6c7d9f6d8b-q9vtd 0/1 ImagePullBackOff 2 (15s ago) 3m
```

With `filterMode: basic`:

- Run 1 and Run 2 are treated as similar (same section types: CrashLoop + ImagePull), so exponential backoff continues.

With `filterMode: strict`:

- Run 1 and Run 2 are treated as different (full lines changed due to pod names/restart counts), so backoff resets as a new pattern.

### Critical cluster stability checks

```yaml
alerts:
  podOOMKilled: true
  podEvicted: true
  pendingUnschedulable: true
  pendingUnschedulableMinPods: 2
  probeFailures: true
  warningEventsSurge: false
  warningEventsSurgeThreshold: 25
  deploymentsHealthCheck: true

deploymentsHealthCheck:
  targets:
    - kube-system/coredns
    - kube-system/metrics-server
    - kube-system/local-path-provisioner
  settings:
    minReadyPercent: 100
    includeZeroDesired: true
    maxReportedLines: 10
    includeMissingTargets: true
```

Recommended tuning:

- Keep `alerts.warningEventsSurge` disabled unless you actively need event-storm detection.
- Increase `alerts.pendingUnschedulableMinPods` to `2` or `3` in large clusters to reduce noise.
- Keep `filters.excludeNamespaces` for non-business namespaces unless you want full visibility.

### 7) Email subject and body templates

Subject template (auto-generated):

```text
K3S ALERT HIGH CrashLoop:2 ImagePull:1 Errors:0 NodeNotReady:1 NodePressure:0
```

You can customize prefix with `smtp.subjectPrefix`.

### 8) Mail format output examples

If `smtp.mailFormat: structured`, the email includes summary + grouped details:

```text
Subject: Kubernetes Alert

[CrashLoop]
default api-7d6dfc4d5b-5qv8z 0/1 CrashLoopBackOff 12 (2m ago) 18m

[ImagePull]
default reports-59fbb8fd6c-kx2dr 0/1 ImagePullBackOff 5 (3m ago) 12m

[NodeNotReady]
k3s-node-2|Ready=False;DiskPressure=False;MemoryPressure=False;PIDPressure=False;
```

If `smtp.mailFormat: compact`, the email is short digest style:

```text
Subject: Kubernetes Alert

Cluster issues detected. Short summary:
[CrashLoop]
default api-7d6dfc4d5b-5qv8z 0/1 CrashLoopBackOff 12 (2m ago) 18m
[ImagePull]
default reports-59fbb8fd6c-kx2dr 0/1 ImagePullBackOff 5 (3m ago) 12m
```

## Disable channels

Email only:

```yaml
channels:
  email:
    enabled: true
  webhook:
    enabled: false
```

Webhook only:

```yaml
channels:
  email:
    enabled: false
  webhook:
    enabled: true
```

## Resource-friendly operation notes

- Keep schedule at 2m or higher for low API load.
- Use `filters.excludeNamespaces` to reduce noisy/system namespaces.
- Keep only required alert classes enabled.
- Concurrency policy is `Forbid` to avoid overlapping jobs.

## RBAC

The chart creates:

- ServiceAccount: `k3s-alert`
- ClusterRole with read-only permissions on:
  - `pods`
  - `nodes`
  - `nodes/status`
  - `events`
- ClusterRole with read/write permissions on:
  - `configmaps` (used for dedupe state in `k3s-alert-state`)
- ClusterRoleBinding bound to the release namespace ServiceAccount.

## Troubleshooting

Check latest jobs:

```bash
kubectl get jobs -n kube-system --sort-by=.metadata.creationTimestamp
```

Check CronJob logs:

```bash
kubectl logs -n kube-system job/<latest-job-name>
```

Render templates before apply:

```bash
helm template k3s-alert . -n kube-system
```

## How To Test

### Script-focused checks (recommended before deploy)

1. Lint and syntax-check rendered runtime script.

```bash
./scripts/test/run-syntax-check.sh .
```

What this does:

- Runs `helm template`
- Extracts rendered `check.sh` from ConfigMap `k3s-alert-script`
- Runs `sh -n` syntax validation
- Runs `shellcheck` if installed

2. Run deterministic mock integration tests (no cluster required).

```bash
./tests/run-mock-tests.sh
```

What this validates:

- First detection sends alert
- Duplicate active finding is suppressed on next run
- Resolution clears active dedupe state
- Reappearance alerts again
- Outbound notification count matches expected behavior

### 1) Deploy chart

```bash
helm upgrade --install k3s-alert . -n kube-system --create-namespace
kubectl get cronjob -n kube-system k3s-alert
```

### 2) Create a test pod with invalid image (to trigger ImagePullBackOff)

```bash
kubectl run k3s-alert-test-fail \
  --image=invalid.registry.example/not-found:latest \
  --restart=Never \
  -n default
```

### 3) Wait for failure and trigger one manual check

```bash
kubectl get pod -n default k3s-alert-test-fail
kubectl create job --from=cronjob/k3s-alert k3s-alert-manual-test-$(date +%s) -n kube-system
kubectl logs -n kube-system job/<latest-job-name>
```

### 4) Verify alert delivery

- Check your email/webhook receiver for alert notification.
- If no alert is received, check cooldown and rate-limit values.

### 5) Cleanup

```bash
kubectl delete pod -n default k3s-alert-test-fail --ignore-not-found
```

## Known behavior

- Dedupe state is persisted in ConfigMap `k3s-alert-state`.
- Ongoing identical findings are suppressed after first successful alert.
- If an issue resolves and later reappears, alert is sent again.
- Cooldown, backoff, and email rate-limit are persisted in `k3s-alert-state` and survive CronJob pod restarts.
