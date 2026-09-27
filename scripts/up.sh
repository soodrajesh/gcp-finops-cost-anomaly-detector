#!/usr/bin/env bash
# Build the whole platform end to end, then prove it works:
#   state bucket -> BigQuery/Pub/Sub/IAM/monitoring/budget -> image build -> Cloud Run Job + Scheduler
#   -> seed the SYNTHETIC billing table -> run the detector once -> live tests.
# Two Terraform phases: the job needs the image digest, so infra comes first.
source "$(dirname "$0")/lib.sh"
PLAN_ONLY=0; SKIP_TESTS=0
for a in "$@"; do case "$a" in --plan) PLAN_ONLY=1;; --skip-tests) SKIP_TESTS=1;; esac; done
need gcloud; need terraform; need bq; need python3

log "Project $PROJECT_ID · $REGION · billing $BILLING_ACCOUNT_ID · admin $ADMIN_EMAIL"
log "1/7 Terraform state bucket"
"$ROOT/scripts/bootstrap.sh" "$PROJECT_ID" "$REGION" >/dev/null && ok "gs://$STATE_BUCKET"
tf_init
[ "$PLAN_ONLY" = 1 ] && { $TF plan -input=false; exit 0; }

log "2/7 Phase 1: BigQuery dataset + tables, Pub/Sub, IAM, monitoring, budget, registry"
# Re-runs must not tear down the Cloud Run Job (phase 2): keep the previous image during phase 1.
if [ -s "$ROOT/.last-image" ]; then TF_VAR_image="$(cat "$ROOT/.last-image")"; export TF_VAR_image; fi
$TF apply -input=false -auto-approve
out() { $TF output -raw "$1"; }
REPO="$(out artifact_repo)"; BUCKET="$(out build_bucket)"; BUILD_SA="$(out build_sa)"
DATASET="$(out dataset)"; SOURCE_TABLE="$(out source_table)"

log "3/7 Seed the SYNTHETIC billing table (seed/synthetic_billing_export.jsonl — NOT live billing data)"
python3 "$ROOT/seed/generate_synthetic_billing.py"
bq --project_id "$PROJECT_ID" load --replace --source_format=NEWLINE_DELIMITED_JSON \
  "${DATASET}.${SOURCE_TABLE}" "$ROOT/seed/synthetic_billing_export.jsonl" \
  "$ROOT/seed/schema_billing_export.json"
ROWS="$(bq_scalar "SELECT COUNT(*) FROM \`${PROJECT_ID}.${DATASET}.${SOURCE_TABLE}\`")"
ok "loaded $ROWS synthetic rows into ${DATASET}.${SOURCE_TABLE}"

log "4/7 Build the image (Cloud Build, dedicated least-privilege SA)"
TAG="v$(date +%y%m%d-%H%M%S)"
gcloud builds submit --project "$PROJECT_ID" --region "$REGION" --config cloudbuild.yaml \
  --service-account "projects/$PROJECT_ID/serviceAccounts/$BUILD_SA" \
  --gcs-source-staging-dir "gs://$BUCKET/src" --substitutions "_REPO=$REPO,_TAG=$TAG" .
DIGEST="$(gcloud artifacts docker images describe "$REPO/detector:$TAG" --format='get(image_summary.digest)')"
IMG="$REPO/detector@$DIGEST"; ok "image $IMG"; echo "$IMG" > "$ROOT/.last-image"

log "5/7 Phase 2: Cloud Run Job + Scheduler + scheduler IAM"
export TF_VAR_image="$IMG"
$TF apply -input=false -auto-approve
JOB="$(out job_name)"; ok "job $JOB"

log "6/7 Run the detector once now (don't wait for tomorrow's schedule)"
EXEC="$(gcloud run jobs execute "$JOB" --project "$PROJECT_ID" --region "$REGION" --wait --format='value(metadata.name)')"
STATUS="$(gcloud run jobs executions describe "$EXEC" --project "$PROJECT_ID" --region "$REGION" --format='value(status.conditions[0].type)' 2>/dev/null || true)"
ok "execution $EXEC finished (status: ${STATUS:-unknown})"

if [ "$SKIP_TESTS" = 1 ]; then log "Skipping tests"; else log "7/7 Live test suite"; "$ROOT/scripts/test.sh"; fi
log "DONE — tear down with ./scripts/down.sh"
