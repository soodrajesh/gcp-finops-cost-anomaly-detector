# Runbook 03 — Cost

Everything here is either free-tier-sized or scales to zero between runs:

| Resource | Cost driver | Typical cost for a build–test–teardown session |
|---|---|---|
| Cloud Run Job | Only bills while an execution runs (a few seconds per run); nothing between runs | Well under €0.01 |
| Cloud Scheduler | 1 job; first 3 jobs/month free | €0.00 |
| BigQuery | ~720 synthetic rows loaded once; queries scan a few hundred KB | Well under €0.01 (free tier covers 1 TB/month of queries) |
| Pub/Sub | A handful of small messages | €0.00 (free tier: 10 GiB/month) |
| Cloud Monitoring | Custom metrics: 2 series, written once per run; log-based metric: free | €0.00 (free tier: 150 MiB/month custom metrics) |
| Cloud Build | One image build (~1-2 minutes) | Well under €0.01 |
| Artifact Registry / GCS build bucket | One small Python image; a 7-day lifecycle rule expires build sources | Well under €0.01 |
| Billing Budget | Free (the API itself has no cost) | €0.00 |

A full `up.sh` → `test.sh` → `down.sh` cycle costs a few cents at most. The Billing
Budget created by Terraform (`terraform/monitoring.tf`, `google_billing_budget`,
default €15/month) is a safety net for if the stack is left running, not an expectation
that it will approach that amount.

**`down.sh` removes everything this repo created**, including the BigQuery dataset and
its data (`delete_contents_on_destroy = true`), so nothing keeps billing after teardown.
It does not touch the shared `<project>-tfstate` bucket unless run with `--purge`, and
even then only removes this repo's prefix inside it — matching the instruction not to
spend effort deleting resources this repo did not create.
