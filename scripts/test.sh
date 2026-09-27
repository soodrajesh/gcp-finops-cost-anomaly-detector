#!/usr/bin/env bash
# Live proof against the deployed platform. Every check asserts something observed, not
# configured. Anomaly correctness is checked against docs/seed-anomalies.json, the
# ground truth written when the SYNTHETIC seed data was generated — see docs/adr/0002.
# "Expected" (from that ground-truth file) is never blurred with "Captured" (what this
# run actually observed): they are printed and compared, not merged into one number.
# Writes docs/test-results.md. Exit code = number of failed checks.
source "$(dirname "$0")/lib.sh"; set +e
need gcloud; need bq; need python3
PASS=0; FAIL=0; OUT="$ROOT/docs/test-results.md"; TMP="$ROOT/.test-tmp"; mkdir -p "$TMP"
{ echo "# Live test results"; echo; echo "Captured by \`scripts/test.sh\` on $(date -u +%FT%TZ) against project \`$PROJECT_ID\` ($REGION)."; echo; echo '```'; } > "$OUT"
say()   { echo "$*" | tee -a "$OUT"; }
check() { # <name> <expected-regex> <actual>
  if grep -qE -- "$2" <<<"$3"; then PASS=$((PASS+1)); say "  PASS  $1  [$(head -c 140 <<<"$3" | tr '\n' ' ')]"
  else FAIL=$((FAIL+1)); say "  FAIL  $1  (wanted /$2/, got: $(head -c 240 <<<"$3" | tr '\n' ' '))"; fi
}
check_not() { # <name> <forbidden-regex> <actual>
  if grep -qE -- "$2" <<<"$3"; then FAIL=$((FAIL+1)); say "  FAIL  $1  (found /$2/ in: $(head -c 240 <<<"$3" | tr '\n' ' '))"
  else PASS=$((PASS+1)); say "  PASS  $1  [absent: $2]"; fi
}
section() { say ""; say "── $* ──"; }

P="$PROJECT_ID"
out() { $TF output -raw "$1"; }
DATASET="$(out dataset)"; SOURCE_TABLE="$(out source_table)"; RESULTS_TABLE="$(out results_table)"
TOPIC="$(out topic)"; SUB="$(out verify_subscription)"; JOB="$(out job_name)"
SCHED="$(out scheduler_job)"; LOG_METRIC="$(out log_metric)"

section "1. Topology"
check "BigQuery dataset exists" "${DATASET}" "$(bq --project_id "$P" show --format=prettyjson "${DATASET}" 2>&1 | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('id',''))" 2>/dev/null)"
check "source + results tables exist" "${SOURCE_TABLE}.*${RESULTS_TABLE}|${RESULTS_TABLE}.*${SOURCE_TABLE}" "$(bq --project_id "$P" ls "$DATASET" 2>/dev/null | tr -s ' \n' ' ')"
check "Cloud Run Job exists" "^${JOB}\$" "$(gcloud run jobs describe "$JOB" --project "$P" --region "$REGION" --format='value(metadata.name)' 2>&1)"
check "Cloud Scheduler job is ENABLED" 'ENABLED' "$(gcloud scheduler jobs describe "$SCHED" --project "$P" --location "$REGION" --format='value(state)' 2>&1)"
check "Pub/Sub topic + subscription exist" "$TOPIC" "$(gcloud pubsub subscriptions describe "$SUB" --project "$P" --format='value(topic)' 2>&1)"

section "2. Synthetic seed data is clearly labelled, not live billing data"
ROWCOUNT="$(bq_scalar "SELECT COUNT(*) FROM \`${P}.${DATASET}.${SOURCE_TABLE}\`")"
check "source table has rows (seeded)" '^[1-9][0-9]*$' "$ROWCOUNT"
NON_SYNTHETIC="$(bq_scalar "SELECT COUNT(*) FROM \`${P}.${DATASET}.${SOURCE_TABLE}\` WHERE is_synthetic = FALSE")"
check "every row is marked is_synthetic = true (0 exceptions)" '^0$' "$NON_SYNTHETIC"

section "3. Detection ran and wrote results"
LATEST_RUN="$(bq_scalar "SELECT run_id FROM \`${P}.${DATASET}.${RESULTS_TABLE}\` ORDER BY detected_at DESC LIMIT 1")"
check "at least one detector run has written to the anomalies table" '.' "$LATEST_RUN"
FLAGGED_THIS_RUN="$(bq_scalar "SELECT COUNT(*) FROM \`${P}.${DATASET}.${RESULTS_TABLE}\` WHERE run_id = '${LATEST_RUN}'")"
say "    latest run_id: $LATEST_RUN  ·  rows flagged this run: $FLAGGED_THIS_RUN"

section "4. Anomaly correctness: Expected (ground truth) vs Captured (this run)"
python3 - "$P" "$DATASET" "$RESULTS_TABLE" "$LATEST_RUN" "$ROOT/docs/seed-anomalies.json" "$TMP/anomaly-check.txt" <<'PYEOF'
import json, subprocess, sys
project, dataset, table, run_id, gt_path, out_path = sys.argv[1:7]

def bq_rows(sql):
    r = subprocess.run(["bq", "--project_id", project, "query", "--nouse_legacy_sql", "--quiet",
                         "--format=json", sql], capture_output=True, text=True)
    return json.loads(r.stdout or "[]")

captured = bq_rows(f"""
    SELECT usage_date, service_description, sku_description, k8s_namespace
    FROM `{project}.{dataset}.{table}` WHERE run_id = '{run_id}'
""")
captured_set = {(r["usage_date"], r["service_description"], r["sku_description"], r.get("k8s_namespace") or None) for r in captured}

with open(gt_path) as f:
    gt = json.load(f)
expected = gt["injected_anomalies"]

lines = []
matched = 0
for e in expected:
    key = (e["usage_date"], e["service_description"], e["sku_description"], e.get("k8s_namespace"))
    hit = key in captured_set
    matched += hit
    lines.append(f"{'CAPTURED' if hit else 'MISSING '}  Expected: {e['usage_date']} {e['service_description']}/{e['sku_description']}"
                 f" ns={e.get('k8s_namespace') or '-'} (x{e['multiplier']}) — {e['story']}")
extra = captured_set - {(e["usage_date"], e["service_description"], e["sku_description"], e.get("k8s_namespace")) for e in expected}
lines.append(f"SUMMARY  {matched}/{len(expected)} expected (synthetic, injected) anomalies were captured by this live run;"
             f" {len(extra)} additional anomalies flagged beyond the injected set")
with open(out_path, "w") as f:
    f.write("\n".join(lines) + "\n")
print(f"RESULT {matched} {len(expected)} {len(extra)}")
PYEOF
ANOMALY_CHECK="$(cat "$TMP/anomaly-check.txt" 2>/dev/null)"
say "$ANOMALY_CHECK"
MATCH_LINE="$(python3 -c "
import json
with open('$ROOT/docs/seed-anomalies.json') as f: gt=json.load(f)
print(len(gt['injected_anomalies']))
")"
check "all $MATCH_LINE injected (synthetic) anomalies were captured" "SUMMARY  ${MATCH_LINE}/${MATCH_LINE} expected" "$ANOMALY_CHECK"

section "5. Alerting: Pub/Sub delivery + log-based metric + alert policies"
PULLED="$(gcloud pubsub subscriptions pull "$SUB" --project "$P" --limit 5 --format='value(message.data)' 2>&1 | head -1)"
check "an anomaly message is on the cost-anomalies subscription" '"usage_date"|z_score' "$PULLED"
LOGM="$(gcloud logging metrics describe "$LOG_METRIC" --project "$P" --format='value(name)' 2>&1)"
check "log-based metric exists" "$LOG_METRIC" "$LOGM"
POL="$(gcloud monitoring policies list --project "$P" --format='value(displayName)' 2>&1)"
check "anomaly-detected alert policy exists" 'cost anomaly detected' "$POL"
check "job-failed alert policy exists" 'detector job execution failed' "$POL"
check "dashboard exists" 'FinOps cost-anomaly detector' "$(gcloud monitoring dashboards list --project "$P" --format='value(displayName)' 2>&1)"

section "6. Budget"
check "billing budget exists" 'finops-cost-anomaly-detector' "$(gcloud billing budgets list --billing-account "$BILLING_ACCOUNT_ID" --format='value(displayName)' 2>&1)"

section "7. IAM least privilege"
for sa in finops-detector finops-scheduler finops-build; do
  n=$(gcloud iam service-accounts keys list --iam-account "$sa@$P.iam.gserviceaccount.com" --managed-by=user --format='value(name)' 2>/dev/null | grep -c .)
  check "$sa: no user-managed keys" '^0$' "$n"
done
DETECTOR_ROLES="$(gcloud projects get-iam-policy "$P" --flatten='bindings[].members' --filter="bindings.members:finops-detector@${P}.iam.gserviceaccount.com" --format='value(bindings.role)' 2>&1 | tr '\n' ' ')"
check_not "finops-detector has no project-level owner/editor role" 'roles/owner|roles/editor' "$DETECTOR_ROLES"
SCHED_ROLES="$(gcloud run jobs get-iam-policy "$JOB" --project "$P" --region "$REGION" --format='value(bindings.members)' 2>&1)"
check "scheduler SA may invoke the job (job-scoped binding)" 'finops-scheduler' "$SCHED_ROLES"
check_not "job is not publicly invocable" 'allUsers' "$SCHED_ROLES"

say '```'; echo >> "$OUT"; echo "**Result: $PASS passed, $FAIL failed.**" >> "$OUT"
echo; [ "$FAIL" = 0 ] && ok "$PASS/$((PASS+FAIL)) checks passed" || warn "$FAIL failed, $PASS passed"
exit "$FAIL"
