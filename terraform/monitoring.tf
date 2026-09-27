resource "google_monitoring_notification_channel" "email" {
  project      = var.project_id
  display_name = "FinOps detector alerts"
  type         = "email"
  labels       = { email_address = var.alert_email }
  depends_on   = [google_project_service.apis]
}

# The detector writes one JSON log line per anomaly with `"anomaly": true` (see
# app/detector/main.py::log). Cloud Run's logging agent parses a valid JSON stdout line
# into jsonPayload automatically, so this metric needs no extra logging client in the app.
resource "google_logging_metric" "anomalies_detected" {
  project     = var.project_id
  name        = "finops_anomalies_detected"
  description = "Count of cost-anomaly log entries emitted by the detector job."
  filter      = <<-EOT
    resource.type="cloud_run_job"
    resource.labels.job_name="finops-anomaly-detector"
    jsonPayload.anomaly=true
  EOT
  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
  }
}

resource "google_monitoring_alert_policy" "anomaly_detected" {
  project      = var.project_id
  display_name = "FinOps: cost anomaly detected"
  combiner     = "OR"
  conditions {
    display_name = "any anomaly log entry in the last 24h"
    condition_threshold {
      filter          = "metric.type=\"logging.googleapis.com/user/${google_logging_metric.anomalies_detected.name}\" AND resource.type=\"cloud_run_job\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0
      duration        = "0s"
      aggregations {
        alignment_period   = "86400s"
        per_series_aligner = "ALIGN_SUM"
      }
    }
  }
  notification_channels = [google_monitoring_notification_channel.email.id]
  documentation {
    content   = "The daily detector run flagged at least one day/service/SKU/namespace as a cost anomaly. Runbook: docs/runbooks/02-run-detection-and-inspect-results.md"
    mime_type = "text/markdown"
  }
  depends_on = [google_project_service.apis]
}

resource "google_monitoring_alert_policy" "job_failed" {
  count        = var.image == "" ? 0 : 1
  project      = var.project_id
  display_name = "FinOps: detector job execution failed"
  combiner     = "OR"
  conditions {
    display_name = "any failed execution of finops-anomaly-detector"
    condition_threshold {
      filter          = "metric.type=\"run.googleapis.com/job/completed_execution_count\" AND resource.type=\"cloud_run_job\" AND resource.label.job_name=\"finops-anomaly-detector\" AND metric.label.result=\"failed\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0
      duration        = "0s"
      aggregations {
        alignment_period   = "3600s"
        per_series_aligner = "ALIGN_SUM"
      }
    }
  }
  notification_channels = [google_monitoring_notification_channel.email.id]
  documentation {
    content   = "The detector job itself crashed (not a business finding — a real fault, e.g. BigQuery/Pub/Sub error). Runbook: docs/runbooks/04-troubleshooting.md"
    mime_type = "text/markdown"
  }
}

resource "google_monitoring_dashboard" "main" {
  project = var.project_id
  dashboard_json = jsonencode({
    displayName = "FinOps cost-anomaly detector"
    mosaicLayout = {
      columns = 12
      tiles = [
        { width = 6, height = 4, widget = { title = "Daily spend total (custom metric, latest run)", xyChart = { dataSets = [{ plotType = "LINE", timeSeriesQuery = { timeSeriesFilter = { filter = "metric.type=\"custom.googleapis.com/finops/daily_spend_total\" resource.type=\"global\"", aggregation = { alignmentPeriod = "3600s", perSeriesAligner = "ALIGN_MEAN" } } } }] } } },
        { xPos = 6, width = 6, height = 4, widget = { title = "Anomalies detected per run", xyChart = { dataSets = [{ plotType = "STACKED_BAR", timeSeriesQuery = { timeSeriesFilter = { filter = "metric.type=\"custom.googleapis.com/finops/anomalies_detected\" resource.type=\"global\"", aggregation = { alignmentPeriod = "3600s", perSeriesAligner = "ALIGN_MAX" } } } }] } } },
        { yPos = 4, width = 6, height = 4, widget = { title = "Anomaly log entries (log-based metric)", xyChart = { dataSets = [{ plotType = "STACKED_BAR", timeSeriesQuery = { timeSeriesFilter = { filter = "metric.type=\"logging.googleapis.com/user/${google_logging_metric.anomalies_detected.name}\" resource.type=\"cloud_run_job\"", aggregation = { alignmentPeriod = "86400s", perSeriesAligner = "ALIGN_SUM" } } } }] } } },
        { xPos = 6, yPos = 4, width = 6, height = 4, widget = { title = "Detector job execution count", xyChart = { dataSets = [{ plotType = "STACKED_BAR", timeSeriesQuery = { timeSeriesFilter = { filter = "metric.type=\"run.googleapis.com/job/completed_execution_count\" resource.type=\"cloud_run_job\"", aggregation = { alignmentPeriod = "3600s", perSeriesAligner = "ALIGN_SUM", groupByFields = ["metric.label.result"], crossSeriesReducer = "REDUCE_SUM" } } } }] } } },
      ]
    }
  })
  depends_on = [google_project_service.apis]
}

resource "google_billing_budget" "this" {
  billing_account = var.billing_account_id
  display_name    = "finops-cost-anomaly-detector"
  amount {
    specified_amount {
      currency_code = "EUR"
      units         = tostring(var.budget_amount)
    }
  }
  budget_filter {
    projects = ["projects/${data.google_project.this.number}"]
  }
  threshold_rules { threshold_percent = 0.5 }
  threshold_rules { threshold_percent = 0.9 }
  threshold_rules { threshold_percent = 1.0 }
  all_updates_rule {
    monitoring_notification_channels = [google_monitoring_notification_channel.email.id]
    disable_default_iam_recipients   = true
  }
  depends_on = [google_project_service.apis]
}
