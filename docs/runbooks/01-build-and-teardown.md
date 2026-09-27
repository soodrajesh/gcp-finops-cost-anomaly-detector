# Runbook 01 — Build and teardown

## Build

```bash
gcloud config set project <your-project>   # billing linked; region/admin/alert email auto-detected
./scripts/up.sh
```

What it does, in order (see `scripts/up.sh`):

1. Creates (if missing) the shared Terraform state bucket `<project>-tfstate`, this
   repo's state living under the `finops-detector` prefix.
2. Terraform phase 1: BigQuery dataset + tables, Pub/Sub topic + subscription, IAM,
   Cloud Monitoring (notification channel, log-based metric, alert policies, dashboard),
   Billing Budget, Artifact Registry repo, build bucket. No Cloud Run Job yet — it needs
   an image digest that doesn't exist until step 4.
3. Regenerates and loads the synthetic seed data (`bq load --replace`) into
   `finops.synthetic_billing_export`.
4. Builds the detector image with Cloud Build, using a dedicated least-privilege build
   service account, and pins the resulting Cloud Run Job to the image **digest** (not a
   mutable tag).
5. Terraform phase 2: creates the Cloud Run Job and the Cloud Scheduler job that
   triggers it daily, plus the IAM binding that lets the scheduler (and only the
   scheduler) invoke it.
6. Runs the detector once immediately (`gcloud run jobs execute --wait`) — no need to
   wait for tomorrow's schedule to see it work.
7. Runs `scripts/test.sh`, the live verification suite.

Useful flags: `--plan` (terraform plan only, no changes), `--skip-tests` (build without
running the live suite).

Re-running `up.sh` is safe: it's idempotent (`bq load --replace`, Terraform apply,
`gcloud run jobs execute` just creates another execution/run_id) and will not tear down
the Cloud Run Job's phase-2 resources on a phase-1-only re-run — the previous image is
kept via `.last-image`.

## Teardown

```bash
./scripts/down.sh            # delete everything this repo created
./scripts/down.sh --purge    # also delete this repo's Terraform state (and the shared bucket if now empty)
```

Order matters only in that Terraform's own dependency graph handles it: the Cloud
Scheduler job, Cloud Run Job, monitoring resources, Pub/Sub topic/subscription, and the
BigQuery dataset (**including its data**, `delete_contents_on_destroy = true`) are all
destroyed by one `terraform destroy`. Nothing in this repo creates resources outside
Terraform's view (no manually-created load balancers or NEGs the way a GKE Gateway
does), so teardown does not need a pre-destroy cleanup step the way some of the other
repos in this project do.

`down.sh` finishes by listing what (if anything) is still billable — every line should
read 0.
