# ADR 0001 — Cloud Run Job, not a Cloud Function, for the detector

**Status:** accepted

The detector is a scheduled batch task: query a day's (or a history's) worth of BigQuery
rows, run a statistical check per group, write results, publish alerts, exit. It has no
inbound HTTP contract to serve and nothing calls it except Cloud Scheduler.

**Cloud Run Job over Cloud Functions (2nd gen) / Cloud Run service:**
- A **Job** models "run to completion, then stop" directly — `google_cloud_run_v2_job`
  has a `max_retries` and a `timeout` built for exactly this, and Cloud Scheduler starts
  an execution through the Cloud Run Admin API (`jobs.run`), not an HTTP request the code
  has to route. A **Cloud Function** would need an HTTP or Pub/Sub trigger wrapper around
  what is really a script, and Cloud Functions' per-invocation timeout (max 60 minutes on
  2nd gen, but billed and modeled as a request) is a worse fit than a Job's execution
  model for something that queries a growing BigQuery table.
- A **Cloud Run *service*** would sit idle waiting for HTTP traffic it never gets; a
  **Job** has no listening container at all between runs, so there is nothing to
  misconfigure into being reachable and nothing billed between executions.
- Same container image, deployment tooling and IAM model (`google_cloud_run_v2_*`,
  attached service account, no keys) as a Cloud Run *service* would use, so this doesn't
  introduce a second runtime to reason about.

**Trade-off:** a Job has no built-in retry-with-backoff across scheduled invocations
(only `max_retries` *within* one execution attempt) and no traffic-splitting/canary
mechanism the way a service does — irrelevant here since there's exactly one thing this
job does and it's idempotent to rerun (each run gets its own `run_id`; reruns just add
more rows, they don't corrupt state). If the detector ever needed to serve results over
HTTP (e.g. a small API in front of the `anomalies` table), that would be a second,
separate Cloud Run *service*, not a mode this Job grows into.
