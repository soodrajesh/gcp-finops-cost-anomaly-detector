resource "google_pubsub_topic" "cost_anomalies" {
  project    = var.project_id
  name       = "cost-anomalies"
  depends_on = [google_project_service.apis]
}

# Pull subscription so scripts/test.sh can prove messages actually arrive, and so a
# real downstream consumer (ticketing system, Slack relay, etc.) has something to bind
# to without this repo having to fake one.
resource "google_pubsub_subscription" "cost_anomalies_verify" {
  project                    = var.project_id
  name                       = "cost-anomalies-verify"
  topic                      = google_pubsub_topic.cost_anomalies.id
  ack_deadline_seconds       = 20
  message_retention_duration = "86400s"
}
