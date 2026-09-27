"""Cloud Run Job entrypoint: FinOps cost-anomaly detection.

Reads daily spend grouped by (service, sku, GKE namespace label) from a BigQuery table
with the same shape as a BigQuery detailed billing export, runs the trailing-window
z-score detector in anomaly.py over each group's whole history, and for every flagged
day:
  1. writes a row to the `anomalies` BigQuery table (the audit trail / dashboard source)
  2. publishes a message to the Pub/Sub topic (the integration point for downstream
     consumers — e.g. a ticketing system in a real deployment)
  3. emits a structured JSON log line with `anomaly: true`, which a log-based metric
     counts, which an alert policy pages on
  4. writes two Cloud Monitoring custom metrics used by the dashboard:
     custom.googleapis.com/finops/daily_spend_total (latest day, all groups)
     custom.googleapis.com/finops/anomalies_detected (count flagged this run)

Whether the source table holds the real BigQuery billing export or the synthetic seed
table is a deployment choice (SOURCE_TABLE env var) — this script does not know or care
which; it is the *seeding* step (seed/generate_synthetic_billing.py) that is responsible
for clearly labelling synthetic data as synthetic. See docs/adr/0002.
"""

from __future__ import annotations

import json
import os
import sys
import time
import uuid
from collections import defaultdict
from datetime import datetime, timezone

from google.cloud import bigquery, pubsub_v1
from google.cloud import monitoring_v3

from detector.anomaly import DayPoint, evaluate_series

PROJECT_ID = os.environ["PROJECT_ID"]
DATASET = os.environ.get("DATASET", "finops")
SOURCE_TABLE = os.environ.get("SOURCE_TABLE", "synthetic_billing_export")
RESULTS_TABLE = os.environ.get("RESULTS_TABLE", "anomalies")
TOPIC_ID = os.environ.get("TOPIC_ID", "cost-anomalies")
Z_THRESHOLD = float(os.environ.get("Z_THRESHOLD", "3.5"))
BASELINE_DAYS = int(os.environ.get("BASELINE_DAYS", "14"))
MIN_BASELINE_POINTS = int(os.environ.get("MIN_BASELINE_POINTS", "7"))
FLAT_PCT_THRESHOLD = float(os.environ.get("FLAT_PCT_THRESHOLD", "0.5"))
DRY_RUN = os.environ.get("DRY_RUN", "false").lower() == "true"


def log(payload: dict) -> None:
    """One JSON line to stdout. Cloud Run's logging agent parses a valid JSON stdout
    line into `jsonPayload`, which is what the `anomaly=true` log-based metric filters
    on (see terraform/monitoring.tf)."""
    print(json.dumps(payload), flush=True)


def fetch_daily_cost(bq: bigquery.Client) -> dict[tuple[str, str, str], list[DayPoint]]:
    query = f"""
        SELECT
          usage_date,
          service_description,
          sku_description,
          COALESCE(k8s_namespace, '') AS k8s_namespace,
          SUM(cost) AS cost
        FROM `{PROJECT_ID}.{DATASET}.{SOURCE_TABLE}`
        GROUP BY usage_date, service_description, sku_description, k8s_namespace
        ORDER BY usage_date
    """
    series: dict[tuple[str, str, str], list[DayPoint]] = defaultdict(list)
    for row in bq.query(query).result():
        key = (row.service_description, row.sku_description, row.k8s_namespace)
        series[key].append(DayPoint(row.usage_date.isoformat(), float(row.cost)))
    return series


def run() -> int:
    run_id = f"{datetime.now(timezone.utc):%Y%m%dT%H%M%S}-{uuid.uuid4().hex[:8]}"
    detected_at = datetime.now(timezone.utc).isoformat()
    bq = bigquery.Client(project=PROJECT_ID)

    log(
        {
            "severity": "INFO",
            "message": "finops-detector starting",
            "run_id": run_id,
            "source_table": f"{PROJECT_ID}.{DATASET}.{SOURCE_TABLE}",
            "z_threshold": Z_THRESHOLD,
            "baseline_days": BASELINE_DAYS,
        }
    )

    series = fetch_daily_cost(bq)
    if not series:
        log(
            {
                "severity": "ERROR",
                "message": "no rows in source table — nothing to evaluate",
                "run_id": run_id,
            }
        )
        return 1

    anomaly_rows = []
    total_days_evaluated = 0
    latest_date = max(p.date for pts in series.values() for p in pts)
    latest_day_total = sum(
        p.cost for pts in series.values() for p in pts if p.date == latest_date
    )

    for (service, sku, namespace), points in series.items():
        results = evaluate_series(
            points,
            baseline_days=BASELINE_DAYS,
            z_threshold=Z_THRESHOLD,
            min_baseline_points=MIN_BASELINE_POINTS,
            flat_series_pct_threshold=FLAT_PCT_THRESHOLD,
        )
        total_days_evaluated += len(results)
        for r in results:
            if not r.is_anomaly:
                continue
            row = {
                "run_id": run_id,
                "detected_at": detected_at,
                "usage_date": r.date,
                "service_description": service,
                "sku_description": sku,
                "k8s_namespace": namespace or None,
                "cost": r.cost,
                "baseline_mean": r.baseline_mean,
                "baseline_stddev": r.baseline_stddev,
                "z_score": r.z_score,
                "pct_deviation": r.pct_deviation,
                "method": r.method,
                "reason": r.reason,
            }
            anomaly_rows.append(row)
            log(
                {
                    "severity": "WARNING",
                    "anomaly": True,
                    "run_id": run_id,
                    "message": f"cost anomaly: {service} / {sku} / ns={namespace or '-'} on {r.date}: "
                    f"€{r.cost:.2f} ({r.reason})",
                    **row,
                }
            )

    log(
        {
            "severity": "INFO",
            "message": "evaluation complete",
            "run_id": run_id,
            "series_count": len(series),
            "day_evaluations": total_days_evaluated,
            "anomalies_detected": len(anomaly_rows),
            "latest_date": latest_date,
            "latest_day_total_cost": round(latest_day_total, 2),
        }
    )

    if DRY_RUN:
        log(
            {
                "severity": "INFO",
                "message": "DRY_RUN=true — skipping BigQuery write / Pub/Sub publish / metrics",
                "run_id": run_id,
            }
        )
        print(
            json.dumps(
                {
                    "run_id": run_id,
                    "anomalies_detected": len(anomaly_rows),
                    "rows": anomaly_rows,
                }
            )
        )
        return 0

    if anomaly_rows:
        table_ref = f"{PROJECT_ID}.{DATASET}.{RESULTS_TABLE}"
        errors = bq.insert_rows_json(table_ref, anomaly_rows)
        if errors:
            log(
                {
                    "severity": "ERROR",
                    "message": "BigQuery insert failed",
                    "run_id": run_id,
                    "errors": errors,
                }
            )
            return 1
        log(
            {
                "severity": "INFO",
                "message": f"wrote {len(anomaly_rows)} rows to {table_ref}",
                "run_id": run_id,
            }
        )

        publisher = pubsub_v1.PublisherClient()
        topic_path = publisher.topic_path(PROJECT_ID, TOPIC_ID)
        futures = [
            publisher.publish(topic_path, json.dumps(r).encode("utf-8"), run_id=run_id)
            for r in anomaly_rows
        ]
        for f in futures:
            f.result(timeout=30)
        log(
            {
                "severity": "INFO",
                "message": f"published {len(futures)} messages to {topic_path}",
                "run_id": run_id,
            }
        )

    write_custom_metrics(latest_day_total, len(anomaly_rows))
    log(
        {
            "severity": "INFO",
            "message": "finops-detector finished",
            "run_id": run_id,
            "anomalies_detected": len(anomaly_rows),
        }
    )
    return 0


def write_custom_metrics(daily_spend_total: float, anomaly_count: int) -> None:
    client = monitoring_v3.MetricServiceClient()
    project_name = f"projects/{PROJECT_ID}"
    now = time.time()
    series_specs = [
        ("custom.googleapis.com/finops/daily_spend_total", daily_spend_total),
        ("custom.googleapis.com/finops/anomalies_detected", float(anomaly_count)),
    ]
    time_series = []
    for metric_type, value in series_specs:
        series = monitoring_v3.TimeSeries()
        series.metric.type = metric_type
        series.resource.type = "global"
        series.resource.labels["project_id"] = PROJECT_ID
        point = monitoring_v3.Point(
            value=monitoring_v3.TypedValue(double_value=value),
            interval=monitoring_v3.TimeInterval(end_time={"seconds": int(now)}),
        )
        series.points = [point]
        time_series.append(series)
    client.create_time_series(name=project_name, time_series=time_series)


if __name__ == "__main__":
    sys.exit(run())
