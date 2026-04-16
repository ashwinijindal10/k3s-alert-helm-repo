# k3s-alert Helm Chart

Lightweight CronJob-based alerting for pod and node failures in k3s/k8s.

## What it monitors

- Pod failures:
  - CrashLoopBackOff
  - ImagePullBackOff / ErrImagePull
  - Error / Failed
  - Restart count over configured threshold (`alerts.podRestartThreshold`)
- Node failures:
  - NotReady
  - Pressure conditions (MemoryPressure, DiskPressure, PIDPressure)

Restart-threshold alerts are one-time per pod after threshold crossing and are tracked with pod annotation `k3s-alert/restart-threshold-notified=true`.

This chart is intentionally simple and resource-friendly:

- Polling model (no long-running watch loops)
- Single CronJob run per interval
- Stateless dedup/cooldown state in pod filesystem (`/tmp`)
- Very low default CPU/memory requests

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
- `cronJob.concurrencyPolicy`: `Forbid`
- `filters.excludeNamespaces`: `kube-system`, `kube-public`

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

- Dedup/cooldown files are stored in `/tmp` inside job pods.
- Because design is stateless, pod restart/new pod may send alerts again for the same ongoing issue.
- This is intentional to keep the chart simple and avoid persistent storage overhead.
