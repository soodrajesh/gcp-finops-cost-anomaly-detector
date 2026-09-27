# Runbook 02 — Run detection and inspect results

## Run it manually

```bash
gcloud run jobs execute finops-anomaly-detector --project "$PROJECT_ID" --region "$REGION" --wait
```

## Inspect flagged anomalies

```bash
bq query --nouse_legacy_sql '
  SELECT run_id, usage_date, service_description, sku_description, k8s_namespace,
         ROUND(cost,2) AS cost, ROUND(z_score,2) AS z_score, method, reason
  FROM `'"$PROJECT_ID"'.finops.anomalies`
  ORDER BY detected_at DESC, z_score DESC
  LIMIT 20'
```

## Compare against the known-injected ground truth

`docs/seed-anomalies.json` lists exactly which (date, service, SKU, namespace) triples
were deliberately injected into the synthetic seed, and why. `scripts/test.sh` §4 does
this comparison automatically and labels the two sides explicitly:

- **Expected** — from `docs/seed-anomalies.json`, generated once, never hand-edited.
- **Captured** — what the most recent live detector run actually wrote to `anomalies`.

The two are printed side by side in `docs/test-results.md`; they are never merged into a
single "N anomalies found" number, so a reader can tell what was *proven* from what was
*known in advance*.

## Point the detector at a real billing export instead of the synthetic seed

Once a project's BigQuery billing export has enough history for a 14-day baseline to
mean something:

1. In `deploy.env`, nothing changes — the Terraform variable that matters is the Cloud
   Run Job's `SOURCE_TABLE` env var (`terraform/run.tf`), currently wired to the
   synthetic table's name via `google_bigquery_table.synthetic_billing_export.table_id`.
2. Change that one line to reference the real export table's ID (and, if it lives in a
   different dataset/project, add `DATASET`/`PROJECT_ID` overrides alongside it).
3. `terraform apply`. Everything downstream — anomaly logic, `anomalies` table schema,
   Pub/Sub, alerting, dashboard — is unchanged, because none of it is aware whether the
   source table is synthetic or real; only the seeding step in `scripts/up.sh` (which you
   would then skip) knows the difference.

## Read the daily spend / anomaly dashboard

```bash
gcloud monitoring dashboards list --project "$PROJECT_ID" --format='value(name)'
```

Open the returned resource name in the Console (Monitoring → Dashboards →
"FinOps cost-anomaly detector"). The two custom-metric tiles only populate after at
least one detector run has executed `write_custom_metrics()`.
