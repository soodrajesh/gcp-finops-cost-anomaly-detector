# The data source: a BigQuery dataset shaped like a real detailed billing-export
# destination. `synthetic_billing_export` is loaded by scripts/up.sh from the
# checked-in, clearly-labelled seed file (seed/synthetic_billing_export.jsonl) — see
# docs/adr/0002 for why. Pointing this at a real export instead is a one-line change:
# set SOURCE_TABLE to the export's table name in deploy.env (docs/runbooks/02).
resource "google_bigquery_dataset" "finops" {
  project                    = var.project_id
  dataset_id                 = "finops"
  location                   = var.region
  description                = "FinOps cost-anomaly detector: synthetic seed data (billing-export shape) + detection results."
  delete_contents_on_destroy = true
  depends_on                 = [google_project_service.apis]
}

resource "google_bigquery_table" "synthetic_billing_export" {
  project             = var.project_id
  dataset_id          = google_bigquery_dataset.finops.dataset_id
  table_id            = "synthetic_billing_export"
  description         = "SYNTHETIC seed data only — same shape as a detailed billing export, never live billing data. See docs/adr/0002 and docs/seed-anomalies.json."
  deletion_protection = false
  schema              = file("${path.module}/../seed/schema_billing_export.json")

  time_partitioning {
    type  = "DAY"
    field = "usage_date"
  }
}

resource "google_bigquery_table" "anomalies" {
  project             = var.project_id
  dataset_id          = google_bigquery_dataset.finops.dataset_id
  table_id            = "anomalies"
  description         = "Flagged anomalies written by each detector run (Cloud Run Job). One row per (run, day, series) that crossed the threshold."
  deletion_protection = false

  schema = jsonencode([
    { name = "run_id", type = "STRING", mode = "REQUIRED" },
    { name = "detected_at", type = "TIMESTAMP", mode = "REQUIRED" },
    { name = "usage_date", type = "DATE", mode = "REQUIRED" },
    { name = "service_description", type = "STRING", mode = "REQUIRED" },
    { name = "sku_description", type = "STRING", mode = "REQUIRED" },
    { name = "k8s_namespace", type = "STRING", mode = "NULLABLE" },
    { name = "cost", type = "FLOAT64", mode = "REQUIRED" },
    { name = "baseline_mean", type = "FLOAT64", mode = "REQUIRED" },
    { name = "baseline_stddev", type = "FLOAT64", mode = "REQUIRED" },
    { name = "z_score", type = "FLOAT64", mode = "REQUIRED" },
    { name = "pct_deviation", type = "FLOAT64", mode = "REQUIRED" },
    { name = "method", type = "STRING", mode = "REQUIRED" },
    { name = "reason", type = "STRING", mode = "REQUIRED" },
  ])

  time_partitioning {
    type  = "DAY"
    field = "detected_at"
  }
}
