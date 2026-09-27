# One identity per job to be done. No service-account keys anywhere: the Cloud Run Job
# uses its attached identity (ADC), Cloud Scheduler authenticates with an OIDC token it
# mints itself, and Cloud Build uses its own dedicated SA for the image build.
locals {
  sas = {
    "finops-detector"  = "Cloud Run Job: reads billing data, writes anomalies, publishes alerts, writes metrics"
    "finops-scheduler" = "Cloud Scheduler: may only start the detector job"
    "finops-build"     = "Cloud Build: builds and pushes the detector image"
  }
}

resource "google_service_account" "sa" {
  for_each     = local.sas
  project      = var.project_id
  account_id   = each.key
  display_name = each.value
  depends_on   = [google_project_service.apis]
}

locals {
  sa_email = { for k, v in google_service_account.sa : k => v.email }
}

# ── detector: least privilege, scoped to the dataset/topic it actually touches ──
resource "google_bigquery_dataset_iam_member" "detector_dataset_editor" {
  project    = var.project_id
  dataset_id = google_bigquery_dataset.finops.dataset_id
  role       = "roles/bigquery.dataEditor"
  member     = "serviceAccount:${local.sa_email["finops-detector"]}"
}

# bigquery.jobUser has no dataset-level equivalent — running a query job always needs
# this at the project level, even when the data it reads/writes is dataset-scoped.
resource "google_project_iam_member" "detector_job_user" {
  project = var.project_id
  role    = "roles/bigquery.jobUser"
  member  = "serviceAccount:${local.sa_email["finops-detector"]}"
}

resource "google_pubsub_topic_iam_member" "detector_publish" {
  project = var.project_id
  topic   = google_pubsub_topic.cost_anomalies.name
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:${local.sa_email["finops-detector"]}"
}

# Custom-metric writes have no resource below "project" to scope to.
resource "google_project_iam_member" "detector_metric_writer" {
  project = var.project_id
  role    = "roles/monitoring.metricWriter"
  member  = "serviceAccount:${local.sa_email["finops-detector"]}"
}

resource "google_project_iam_member" "detector_log_writer" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${local.sa_email["finops-detector"]}"
}

# ── scheduler: only allowed to invoke this one job ──
resource "google_cloud_run_v2_job_iam_member" "scheduler_invoker" {
  count    = var.image == "" ? 0 : 1
  project  = var.project_id
  location = var.region
  name     = google_cloud_run_v2_job.detector[0].name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${local.sa_email["finops-scheduler"]}"
}

# ── build ──
resource "google_artifact_registry_repository" "images" {
  project       = var.project_id
  location      = var.region
  repository_id = "finops"
  format        = "DOCKER"
  depends_on    = [google_project_service.apis]
}

resource "google_storage_bucket" "build" {
  project                     = var.project_id
  name                        = "${var.project_id}-finops-build"
  location                    = var.region
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = true
  lifecycle_rule {
    condition { age = 7 }
    action { type = "Delete" }
  }
}

resource "google_project_iam_member" "build_logs" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${local.sa_email["finops-build"]}"
}

resource "google_artifact_registry_repository_iam_member" "build_push" {
  project    = var.project_id
  location   = var.region
  repository = google_artifact_registry_repository.images.name
  role       = "roles/artifactregistry.writer"
  member     = "serviceAccount:${local.sa_email["finops-build"]}"
}

resource "google_storage_bucket_iam_member" "build_src" {
  bucket = google_storage_bucket.build.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${local.sa_email["finops-build"]}"
}

# operator (the human running scripts/*.sh) may execute the job manually and read BigQuery
resource "google_project_iam_member" "operator" {
  for_each = toset(["roles/run.developer", "roles/bigquery.dataViewer"])
  project  = var.project_id
  role     = each.value
  member   = "user:${var.admin_email}"
}
