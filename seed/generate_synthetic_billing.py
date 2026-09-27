#!/usr/bin/env python3
"""Generate a SYNTHETIC daily-cost table with the same shape as a BigQuery detailed
billing export, plus a ground-truth file listing the anomalies deliberately injected
into it.

Why synthetic data at all: BigQuery billing export only starts populating once it is
enabled on a project — it has no history on day one. A z-score/moving-average detector
needs weeks of baseline to mean anything. Rather than pretend a brand-new project has
history it doesn't, this script builds a clearly-labelled synthetic table (every row has
is_synthetic = true) with a known, printed ground truth, so the detector can be proven
against known-in-advance answers instead of hoped-for real spend. See docs/adr/0002.

Output:
  seed/synthetic_billing_export.jsonl   — one JSON object per row, ready for `bq load`
  docs/seed-anomalies.json              — ground truth: date/group/multiplier for every
                                           injected anomaly, used by scripts/test.sh to
                                           assert "Captured" matches "Expected"

Deterministic: fixed random seed, so re-running produces byte-identical output.

    python3 seed/generate_synthetic_billing.py
"""

from __future__ import annotations

import json
import os
import random
from datetime import date, timedelta

random.seed(20260927)

DAYS = 90
END = date(2026, 9, 27)  # "today" for this synthetic history
START = END - timedelta(days=DAYS - 1)
PROJECT_ID = "claude-code-507112"
CURRENCY = "EUR"

# (service, sku, namespace-or-None, base_daily_cost, weekday_dip, noise_pct)
GROUPS = [
    ("Compute Engine", "N2 Instance Core running in EMEA", None, "europe-west1", 42.0, False, 0.06),
    ("Cloud Storage", "Standard Storage EMEA", None, "europe-west1", 8.5, False, 0.03),
    ("BigQuery", "Analysis", None, "europe-west1", 6.0, True, 0.20),
    ("Cloud SQL", "SQL Enterprise - Instance vCPU running in EMEA", None, "europe-west1", 18.0, False, 0.04),
    ("Kubernetes Engine", "Autopilot vCPU", "checkout", "europe-west1", 22.0, True, 0.08),
    ("Kubernetes Engine", "Autopilot vCPU", "payments", "europe-west1", 15.0, True, 0.07),
    ("Kubernetes Engine", "Autopilot vCPU", "platform", "europe-west1", 9.0, True, 0.06),
    ("Kubernetes Engine", "Autopilot Memory", "checkout", "europe-west1", 11.0, True, 0.08),
]

# Deliberately injected anomalies: (day_offset_from_start, service, sku, namespace, multiplier, story)
INJECTED = [
    (50, "Kubernetes Engine", "Autopilot vCPU", "checkout", 9.0,
     "runaway retry loop in a checkout batch job spiked GKE vCPU cost in the checkout namespace for one day"),
    (65, "BigQuery", "Analysis", None, 12.0,
     "an unscheduled one-off backfill query scanned far more data than a normal day's analysis queries"),
    (82, "Kubernetes Engine", "Autopilot Memory", "checkout", 6.0,
     "a memory leak in a checkout service drove up GKE memory-request cost in the checkout namespace"),
]


def daily_cost(base: float, weekday_dip: bool, noise_pct: float, d: date, rng: random.Random) -> float:
    cost = base
    if weekday_dip and d.weekday() >= 5:  # weekends lighter for compute-ish services
        cost *= 0.55
    # gentle upward drift over the quarter (~15% growth), like real organic growth
    growth = 1.0 + 0.15 * ((d - START).days / DAYS)
    cost *= growth
    cost *= 1.0 + rng.uniform(-noise_pct, noise_pct)
    return round(max(cost, 0.0), 4)


def main() -> None:
    rng = random.Random(20260927)
    rows = []
    injected_by_key = {(off, svc, sku, ns): mult for off, svc, sku, ns, mult, _ in INJECTED}

    for i in range(DAYS):
        d = START + timedelta(days=i)
        for svc, sku, ns, loc, base, dip, noise in GROUPS:
            cost = daily_cost(base, dip, noise, d, rng)
            mult = injected_by_key.get((i, svc, sku, ns))
            if mult is not None:
                cost = round(cost * mult, 4)
            rows.append({
                "usage_date": d.isoformat(),
                "project_id": PROJECT_ID,
                "service_description": svc,
                "sku_description": sku,
                "location": loc,
                "k8s_namespace": ns,
                "cost": cost,
                "currency": CURRENCY,
                "is_synthetic": True,
            })

    out_dir = os.path.dirname(__file__)
    jsonl_path = os.path.join(out_dir, "synthetic_billing_export.jsonl")
    with open(jsonl_path, "w", encoding="utf-8") as fh:
        for r in rows:
            fh.write(json.dumps(r) + "\n")

    ground_truth = {
        "generated_from": "seed/generate_synthetic_billing.py",
        "note": "SYNTHETIC ground truth for the injected anomalies below. These are the only "
                "days scripts/test.sh expects the live detector to flag as anomalies (Expected). "
                "Whatever the detector actually flags on a live run is recorded separately as "
                "Captured in docs/test-results.md — the two are never merged into one number.",
        "history_start": START.isoformat(),
        "history_end": END.isoformat(),
        "row_count": len(rows),
        "injected_anomalies": [
            {
                "usage_date": (START + timedelta(days=off)).isoformat(),
                "service_description": svc,
                "sku_description": sku,
                "k8s_namespace": ns,
                "multiplier": mult,
                "story": story,
            }
            for off, svc, sku, ns, mult, story in INJECTED
        ],
    }
    gt_path = os.path.join(out_dir, "..", "docs", "seed-anomalies.json")
    with open(gt_path, "w", encoding="utf-8") as fh:
        json.dump(ground_truth, fh, indent=2)
        fh.write("\n")

    print(f"wrote {len(rows)} rows -> {jsonl_path}")
    print(f"wrote ground truth ({len(INJECTED)} injected anomalies) -> {gt_path}")


if __name__ == "__main__":
    main()
