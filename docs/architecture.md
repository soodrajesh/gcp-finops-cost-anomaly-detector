# Architecture

See the [diagram](img/architecture.svg) ([source](diagrams/architecture.py)) for the
numbered flow. This page is the prose walkthrough.

## The data source

`terraform/bigquery.tf` creates a `finops` BigQuery dataset with two tables:

- `synthetic_billing_export` — shaped exactly like a BigQuery detailed billing export
  (service, SKU, location, the `k8s_namespace` GKE cost-allocation label, daily cost),
  loaded by `scripts/up.sh` from `seed/synthetic_billing_export.jsonl`. **Every row is
  synthetic**, marked `is_synthetic = true`, generated deterministically by
  `seed/generate_synthetic_billing.py` with 3 deliberately injected anomalies. See
  [ADR 0002](adr/0002-synthetic-seed-data-for-anomaly-baseline.md) for why, and
  [runbook 02](runbooks/02-run-detection-and-inspect-results.md) for pointing this at a
  real export instead.
- `anomalies` — written by the detector job; one row per (run, day, service, SKU,
  namespace) that crossed the anomaly threshold, with the full statistical reasoning
  (baseline mean/stddev, z-score, method, human-readable reason) kept for audit.

## The detector (`app/detector/`)

A Cloud Run **Job** (not a service — see [ADR 0001](adr/0001-cloud-run-job-over-cloud-function.md)),
triggered daily by Cloud Scheduler:

1. Queries `synthetic_billing_export`, grouping daily cost by
   `(service_description, sku_description, k8s_namespace)`.
2. For each group's full history, `detector/anomaly.py` evaluates every day against a
   trailing baseline of up to 14 prior days from *that same group*: a z-score check
   (flag if `|z| >= 3.5`), falling back to a plain percentage-deviation check when the
   baseline is too flat for a z-score to mean anything (near-zero variance would
   otherwise make trivial noise look infinitely anomalous).
3. Every flagged day is written to `anomalies`, published to the `cost-anomalies` Pub/Sub
   topic, and logged as one structured JSON line (`anomaly: true`) to stdout.
4. Two Cloud Monitoring custom metrics are written for the dashboard: the latest day's
   total spend across all groups, and how many anomalies this run flagged.

The method is intentionally simple — no seasonality model, no ML — and that trade-off is
named, not hidden: see the README's known-gaps section and
[ADR 0002](adr/0002-synthetic-seed-data-for-anomaly-baseline.md).

## Alerting and observability

Two independent paths from the same event, deliberately not merged into one mechanism —
see [ADR 0003](adr/0003-log-metric-and-pubsub-for-alerting.md):

- **Paging:** Cloud Logging → a log-based metric (`finops_anomalies_detected`, counting
  `jsonPayload.anomaly=true` entries) → a Cloud Monitoring alert policy → email. A second,
  independent alert policy pages if the job execution itself fails (a real fault, not a
  business finding).
- **Integration:** every anomaly is also published to Pub/Sub (`cost-anomalies`), the
  point a real deployment would hang a ticketing or chat integration off. This repo does
  not wire a live external webhook; `scripts/test.sh` proves delivery against a
  dedicated pull subscription instead.
- A Cloud Monitoring **dashboard** charts daily spend, anomalies detected per run, the
  log-based metric, and job execution outcomes.
- A Terraform-managed **Billing Budget** alerts the same channel at 50/90/100% of a
  configurable monthly amount.

## Identity and access

Three service accounts, one per job to be done (`terraform/identities.tf`):
`finops-detector` (dataset-scoped BigQuery access, topic-scoped Pub/Sub publish,
project-level metric/log writes — BigQuery and Monitoring have no finer scope for those
specific actions), `finops-scheduler` (invoke *this job only*), `finops-build`
(push to *this one* Artifact Registry repo). No service-account keys anywhere; the job,
scheduler and build all authenticate as their attached identity. Full mapping in the
[threat model](threat-model.md).
