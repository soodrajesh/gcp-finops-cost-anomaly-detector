# Threat model (STRIDE)

| Threat | Control | Proven by |
|---|---|---|
| **S**poofed trigger (something other than Cloud Scheduler starting the job) | Job invocation requires `roles/run.invoker`, granted only to the `finops-scheduler` SA on this one job (not project-wide); the job itself accepts no inbound HTTP | test §7: job IAM policy contains only `finops-scheduler`, no `allUsers` |
| **S**poofed data source | The detector queries a named BigQuery table it has `dataEditor` on via an explicit dataset-scoped binding, not a wildcard; swapping `SOURCE_TABLE` to a real export is a config change under human control, not something an attacker can redirect at runtime | Terraform: `google_bigquery_dataset_iam_member` scoped to the `finops` dataset only |
| **T**ampered anomaly results | Only the `finops-detector` SA has write access to the `anomalies` table (dataset-level `dataEditor`); no other identity in this repo can write to it | Terraform IAM; test §7 |
| **T**ampered synthetic seed data presented as real | Every synthetic row carries `is_synthetic = true`; the table name (`synthetic_billing_export`) and every doc/diagram label it SYNTHETIC; nothing in the repo claims it is live billing data | test §2: `is_synthetic = FALSE` count is asserted to be exactly 0 |
| **R**epudiation | Every detector run has a unique `run_id` and `detected_at` timestamp; every flagged row records the method and the exact reason (z-score / baseline / threshold) it was flagged | `anomalies` table rows; test §3–4 |
| **I**nformation disclosure | No service is public; the job has no inbound endpoint at all; the BigQuery dataset and Pub/Sub topic have no `allUsers`/`allAuthenticatedUsers` bindings; no service-account keys exist to leak | test §7 |
| **D**enial of service | Cloud Run Job `max_retries = 1` (no retry storm); a dedicated alert pages if the job execution itself fails (distinct from a normal "no anomalies found" run); a Billing Budget bounds total spend | test §5; job-failure alert policy in `terraform/monitoring.tf` |
| **E**levation of privilege | Three separate identities (`finops-detector`, `finops-scheduler`, `finops-build`), each with only the roles listed in `terraform/identities.tf`; none holds `roles/owner` or `roles/editor` at the project level; `bigquery.jobUser` and `monitoring.metricWriter` are project-level only because BigQuery and Cloud Monitoring have no finer-grained equivalent for those specific actions | test §7: explicit check that `finops-detector`'s project-level roles never include owner/editor |

**Out of scope (deliberate, see README known gaps):** no CMEK on the BigQuery dataset,
no VPC-SC perimeter, no real external notification integration (Slack/ticketing) beyond
the Pub/Sub integration point, single region, and detection quality against genuinely
noisy real-world spend (as opposed to the synthetic seed's clean injected spikes) is
unproven — see [ADR 0002](adr/0002-synthetic-seed-data-for-anomaly-baseline.md).
