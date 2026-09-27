#!/usr/bin/env bash
# Delete everything this repo created, end to end.
#   ./scripts/down.sh            destroy the platform (keeps the tiny shared Terraform state bucket)
#   ./scripts/down.sh --purge    also delete this repo's Terraform state (and the bucket if now empty)
source "$(dirname "$0")/lib.sh"
need gcloud; need terraform
PURGE=0; [ "${1:-}" = "--purge" ] && PURGE=1

log "Project $PROJECT_ID — destroying everything managed by this repo"
tf_init
TF_VAR_image="$(cat "$ROOT/.last-image" 2>/dev/null || echo "")"; export TF_VAR_image
log "1/2 Terraform destroy (Cloud Run Job, Scheduler, BigQuery dataset incl. data, Pub/Sub, budget, registry, bucket)"
$TF destroy -input=false -auto-approve
ok "platform destroyed"
rm -f "$ROOT/.last-image"; rm -rf "$ROOT/.test-tmp"

if [ "$PURGE" = 1 ]; then
  log "2/2 Purging this repo's Terraform state"
  gcloud storage rm -r "gs://$STATE_BUCKET/finops-detector/" --quiet >/dev/null 2>&1 || true
  if [ -z "$(gcloud storage ls "gs://$STATE_BUCKET/" 2>/dev/null)" ]; then
    gcloud storage rm -r "gs://$STATE_BUCKET" --quiet >/dev/null 2>&1 || true; ok "state prefix and (now empty) bucket removed"
  else ok "state prefix removed; bucket kept because other stacks still use it"; fi
else log "2/2 Kept state bucket gs://$STATE_BUCKET (a few KB; --purge removes it)"; fi

log "Anything billable left?"
echo "  Cloud Run jobs (finops-anomaly-detector): $(gcloud run jobs list --project "$PROJECT_ID" --region "$REGION" --format='value(name)' 2>/dev/null | grep -c '^finops-anomaly-detector$' || true)"
echo "  Cloud Scheduler jobs:  $(gcloud scheduler jobs list --project "$PROJECT_ID" --location "$REGION" --format='value(name)' 2>/dev/null | grep -c 'finops-daily-detection' || true)"
echo "  BigQuery datasets (finops): $(bq --project_id "$PROJECT_ID" ls -d 2>/dev/null | grep -c ' finops *$' || true)"
echo "  Pub/Sub topics (cost-anomalies): $(gcloud pubsub topics list --project "$PROJECT_ID" --format='value(name)' 2>/dev/null | grep -c 'cost-anomalies$' || true)"
echo "  Artifact Registry (finops): $(gcloud artifacts repositories list --project "$PROJECT_ID" --location "$REGION" --format='value(name)' 2>/dev/null | grep -c '/finops$' || true)"
echo "  Billing budgets (finops-cost-anomaly-detector): $(gcloud billing budgets list --billing-account "$BILLING_ACCOUNT_ID" --format='value(displayName)' 2>/dev/null | grep -c '^finops-cost-anomaly-detector$' || true)"
log "DONE"
