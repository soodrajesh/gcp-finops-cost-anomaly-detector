# ADR 0003 — Two alerting paths from one event: a log-based metric for paging, Pub/Sub for integration

**Status:** accepted

Every flagged anomaly needs to (a) page a human via Cloud Monitoring and (b) be
available to whatever a real deployment would eventually wire up downstream (a ticket,
a Slack message, a spend-freeze automation). Those are different jobs and this repo
gives them different mechanisms rather than overloading one:

- **Cloud Logging → log-based metric → alert policy.** The detector prints one JSON line
  per anomaly to stdout with `anomaly: true`; Cloud Run's logging agent parses a valid
  JSON stdout line into `jsonPayload` automatically, so no logging client library is
  needed in the app. `google_logging_metric` counts entries matching
  `jsonPayload.anomaly=true`, and a `google_monitoring_alert_policy` fires when that
  count is above zero in a day. This is the **paging path** — it is what Cloud Monitoring
  is for, and it's how the sibling repos in this project already alert
  (`gcp-serverless-orders-platform`'s saga-failure alert works the same way).
- **Pub/Sub (`cost-anomalies` topic).** Every anomaly is also published as a message.
  This is the **integration path**: a real deployment would subscribe a ticketing
  webhook, a Slack relay, or a spend-freeze Cloud Function to this topic. This repo does
  **not** wire a real Slack webhook or ticketing integration — the user's instructions
  for this build were explicit that a demo should not carry a live external webhook — so
  `scripts/test.sh` proves delivery the honest way available without one: it pulls from
  a dedicated verification subscription (`cost-anomalies-verify`) and asserts a message
  actually arrived, with the same JSON payload written to BigQuery.

**Why not only one of the two:** a log-based metric has no natural "replay this event
into my ticketing system" shape — it's a count, not a message. Pub/Sub has no built-in
notion of "page someone if this queue has ever had a message," and building that on top
of Pub/Sub (a subscriber that talks to Cloud Monitoring) would just be reinventing the
log-based-metric path with more moving parts. Two purpose-built, narrow mechanisms beat
one general one bent to do both jobs.
