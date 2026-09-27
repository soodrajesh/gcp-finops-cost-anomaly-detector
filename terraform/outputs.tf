output "artifact_repo" { value = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.images.repository_id}" }
output "build_bucket" { value = google_storage_bucket.build.name }
output "build_sa" { value = local.sa_email["finops-build"] }
output "dataset" { value = google_bigquery_dataset.finops.dataset_id }
output "source_table" { value = google_bigquery_table.synthetic_billing_export.table_id }
output "results_table" { value = google_bigquery_table.anomalies.table_id }
output "topic" { value = google_pubsub_topic.cost_anomalies.name }
output "verify_subscription" { value = google_pubsub_subscription.cost_anomalies_verify.name }
output "job_name" { value = var.image == "" ? "" : google_cloud_run_v2_job.detector[0].name }
output "scheduler_job" { value = var.image == "" ? "" : google_cloud_scheduler_job.daily_detection[0].name }
output "log_metric" { value = google_logging_metric.anomalies_detected.name }
