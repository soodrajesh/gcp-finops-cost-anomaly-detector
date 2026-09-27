# A job, not a service: the detector has no inbound traffic, runs on a schedule, exits
# when done, and bills nothing between runs. See docs/adr/0001.
resource "google_cloud_run_v2_job" "detector" {
  count               = var.image == "" ? 0 : 1
  project             = var.project_id
  name                = "finops-anomaly-detector"
  location            = var.region
  deletion_protection = false

  template {
    template {
      service_account = local.sa_email["finops-detector"]
      max_retries     = 1
      timeout         = "540s"
      containers {
        image = var.image
        env {
          name  = "PROJECT_ID"
          value = var.project_id
        }
        env {
          name  = "DATASET"
          value = google_bigquery_dataset.finops.dataset_id
        }
        env {
          name  = "SOURCE_TABLE"
          value = google_bigquery_table.synthetic_billing_export.table_id
        }
        env {
          name  = "RESULTS_TABLE"
          value = google_bigquery_table.anomalies.table_id
        }
        env {
          name  = "TOPIC_ID"
          value = google_pubsub_topic.cost_anomalies.name
        }
        env {
          name  = "Z_THRESHOLD"
          value = tostring(var.z_threshold)
        }
        env {
          name  = "BASELINE_DAYS"
          value = tostring(var.baseline_days)
        }
        resources {
          limits = { cpu = "1", memory = "512Mi" }
        }
      }
    }
  }
  depends_on = [
    google_bigquery_dataset_iam_member.detector_dataset_editor,
    google_project_iam_member.detector_job_user,
    google_pubsub_topic_iam_member.detector_publish,
    google_project_iam_member.detector_metric_writer,
    google_project_iam_member.detector_log_writer,
  ]
}
