# Runbook 04 — Troubleshooting

Problems actually hit while building this repo, and the fix. (Updated after the live
build in this session — see the root README's status line for when.)

## `write_custom_metrics()` crashed the job: `'NoneType' object has no attribute 'FromSeconds'`

Hit on the very first live execution. The original code built a `monitoring_v3.Point()`
and then tried to mutate its nested `interval.end_time` in place with
`point.interval.end_time.FromSeconds(int(now))` — with this version of
`google-cloud-monitoring`'s proto-plus wrapper, accessing that nested field before it has
ever been assigned returns `None` rather than an empty message you can mutate. The
detector had already written the anomalies to BigQuery and published to Pub/Sub by this
point in the run (both come before the metrics write in `main.py`), so the practical
effect was a "successful" detection with a job execution recorded as `failed` — a good
example of why the job-execution-failed alert policy is separate from the
anomaly-detected one (see [ADR 0003](../adr/0003-log-metric-and-pubsub-for-alerting.md)):
one caught the crash even though the actual anomaly detection had already fully worked.

Fix: construct the `Point` and its nested `TimeInterval`/`TypedValue` in one call instead
of mutating fields after the fact:

```python
point = monitoring_v3.Point(
    value=monitoring_v3.TypedValue(double_value=value),
    interval=monitoring_v3.TimeInterval(end_time={"seconds": int(now)}),
)
```

Confirmed by a from-scratch `./scripts/up.sh` run afterwards: 21/21 live checks passed.

## `bq load` fails with a schema mismatch

`seed/schema_billing_export.json` and `seed/generate_synthetic_billing.py` must agree on
field names/types. If either is edited independently, `bq load --replace` fails fast
with a clear schema-mismatch error rather than silently loading wrong data — regenerate
both together (`python3 seed/generate_synthetic_billing.py`) before loading.

## `terraform apply` phase 2 fails: "Job does not exist" for the scheduler/IAM binding

The Cloud Run Job (`google_cloud_run_v2_job.detector`), the scheduler IAM binding, and
the Cloud Scheduler job itself are all `count = var.image == "" ? 0 : 1` — they don't
exist during phase 1. If `TF_VAR_image` isn't set to a real digest before phase 2's
`apply`, Terraform will try to create the scheduler job pointing at a job resource that
doesn't exist yet. `scripts/up.sh` sets `TF_VAR_image` from the Cloud Build output before
running phase 2 — running `terraform apply` by hand without exporting `TF_VAR_image`
first will reproduce this.

## The detector job execution succeeds but no anomalies are ever flagged

Check `MIN_BASELINE_POINTS` (default 7) against how much history is actually loaded — a
group needs at least that many prior days before any day is judged at all (by design:
days without enough baseline are skipped, not silently flagged or silently passed). With
the 90-day synthetic seed this is never an issue; it would be the first thing to check
if `SOURCE_TABLE` is pointed at a freshly-enabled real billing export with under two
weeks of history.

## Running the detector locally without a service-account key

The detector runs as its attached service account (`finops-detector`) inside Cloud Run —
there's no key to authenticate with locally, by design. To run `app/detector/main.py`
outside Cloud Run for local debugging, either `gcloud auth application-default login` as
a principal with the same BigQuery/Pub/Sub/Monitoring roles, or set `DRY_RUN=true` (see
`app/detector/main.py`) to evaluate anomalies and print the result without touching
BigQuery, Pub/Sub, or Monitoring at all.
