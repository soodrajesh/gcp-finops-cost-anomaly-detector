#!/usr/bin/env python3
"""Generates docs/img/architecture.svg (PNG via docs/diagrams/render.py).

    python3 docs/diagrams/architecture.py
"""

import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
from archlib import Diagram  # noqa: E402

OUT = os.path.join(os.path.dirname(__file__), "..", "img", "architecture.svg")

W, H = 1780, 1300
d = Diagram(W, H, "FinOps Cost-Anomaly Detector on Google Cloud",
            "BigQuery billing data · Cloud Run Job (z-score detector) · Pub/Sub + log-based metric alerting · Cloud Monitoring · Terraform")

d.group(190, 100, 1480, 650, "Google Cloud project  ·  europe-west1", "#1a73e8", dash=False, fill="#f8faff", label_w=330)

# ── row 1 (y=250): data source, results, dashboard ──────────────────────────────────
d.node("seed", 70, 250, "seed script", "dev", "dev", "generate_synthetic_\nbilling_export.py")
d.node("src", 330, 250, "synthetic_billing_\nexport", "db", "data", "BigQuery · SYNTHETIC\n90d history, 3 injected\nanomalies (labelled)")
d.node("res", 700, 250, "anomalies", "db", "data", "BigQuery · run_id,\nz-score, reason")
d.node("dash", 1560, 250, "Dashboard", "chart", "ops", "spend · anomalies\nexecutions")

# ── row 2 (y=420): the job + trigger + eventing + budget ────────────────────────────
d.node("sched", 330, 420, "Cloud Scheduler", "filter", "ops", "daily cron\nOAuth token, no keys")
d.node("job", 700, 420, "finops-anomaly-\ndetector", "run", "compute", "Cloud Run Job (z-score)")
d.node("topic", 1000, 420, "Pub/Sub", "bolt", "data", "cost-anomalies")
d.node("sub", 1280, 420, "verify sub", "bolt", "data", "pull subscription")
d.node("budget", 1560, 420, "Billing Budget", "money", "ops", "50 / 90 / 100%")

# ── row 3 (y=630): alerting chain ────────────────────────────────────────────────────
d.node("logs", 700, 630, "Cloud Logging", "policy", "ops", "structured JSON\nanomaly=true")
d.node("metric", 1000, 630, "Log-based metric", "chart", "ops", "finops_anomalies_\ndetected")
d.node("alert", 1280, 630, "Alert policy", "bolt", "ops", "> 0 in 24h")
d.node("chan", 1560, 630, "Email channel", "user", "actor", "alert_email")

d.edge("seed", "src", "h")
d.edge("sched", "job", "h", num=1, label="POST jobs.run (OAuth token)")
d.edge("src", "job", "vh", num=2, label="query daily spend by\nservice / SKU / namespace", sides=("b", "t"))
d.edge("job", "res", "vh", num=3, label="write flagged rows", sides=("t", "b"))
d.edge("job", "topic", "h", num=4, label="publish anomaly")
d.edge("topic", "sub", "h")
d.edge("job", "logs", "v", num=5, label="one JSON line per\nanomaly (stdout)")
d.edge("logs", "metric", "h")
d.edge("metric", "alert", "h", num=6)
d.edge("alert", "chan", "h", num=7, label="pages on real findings")
d.path([(700, 390), (700, 320), (1560, 320), (1560, 280)], num=8, label="custom metrics (daily spend, anomaly count)", lab_at=(1130, 308))
d.edge("budget", "chan", "v", num=9, label="50/90/100%\nof spend", lab_dy=6)

d.badge(250, 760, "10", "#1e8e3e")
d.text(270, 765, "Every SA is scoped to its job: the detector may only touch the finops dataset, the cost-anomalies topic and project-level metric/log writes;", 12, "#3c4043")
d.text(270, 783, "the scheduler may only invoke this one job. No service-account keys anywhere. No project-level owner/editor role held by any of them.", 12, "#3c4043")

d.band(190, 800, 1480, 130, "HONESTY ABOUT THE DATA  ·  see docs/adr/0002", "#d93025", "#fff8f7")
d.text(220, 842, "BigQuery billing export only starts populating once enabled — a fresh project has no history to detect anomalies against.", 12.5, "#3c4043")
d.text(220, 866, "synthetic_billing_export is a clearly-labelled synthetic seed table (is_synthetic = true on every row) with 3 deliberately injected anomalies.", 12.5, "#3c4043")
d.text(220, 890, "Pointing SOURCE_TABLE at a real billing-export table instead is a one-line config change (docs/runbooks/02) — nothing else in this diagram changes.", 12.5, "#3c4043")

d.legend(34, 960, "Numbered flows", [
    ("1", "Cloud Scheduler calls the Cloud Run Admin API to start the job, authenticating with its own service account's OAuth token"),
    ("2", "The job queries daily cost grouped by service, SKU and GKE namespace cost-allocation label"),
    ("3", "Each series is evaluated against its own 14-day trailing baseline (z-score, falling back to % deviation for flat series); flagged days are written to the anomalies table"),
    ("4", "Every flagged anomaly is published to Pub/Sub for downstream consumers"),
    ("5", "The job also emits one structured JSON log line per anomaly to stdout"),
    ("6", "A log-based metric counts those log entries"),
    ("7", "An alert policy fires on the metric and notifies the email channel — a second policy alerts if the job itself crashes"),
    ("8", "The job writes two custom Cloud Monitoring metrics (daily spend total, anomalies this run) that the dashboard charts"),
    ("9", "A Terraform-managed Billing Budget alerts the same channel at 50/90/100% of the monthly amount"),
], w=1720)
d.key(34, 1230)

d.save(OUT)
print("wrote", os.path.abspath(OUT))
