# ADR 0002 — Synthetic, clearly-labelled seed data instead of waiting on real billing history

**Status:** accepted

**The constraint:** BigQuery's detailed billing export only starts writing rows the
moment it is enabled on a project — it has no backfill. A z-score / moving-average
anomaly detector needs at least a couple of weeks of baseline per (service, SKU, label)
group before "is today unusual" means anything. A project stood up for this repo cannot,
within one build session, accumulate 90 days of real spend history.

**The decision:** `seed/generate_synthetic_billing.py` deterministically (fixed random
seed) generates a table with the **exact same schema** a real detailed billing export
would produce (`seed/schema_billing_export.json`) — service, SKU, location, the GKE
`k8s_namespace` cost-allocation label, daily cost — covering 90 days, with **3
deliberately injected anomalies** at known dates/groups/multipliers. That ground truth is
written alongside the data to `docs/seed-anomalies.json` and is never edited by hand
after generation.

**What this buys, and what it costs:**
- It lets the detector be proven against **known-in-advance answers** (`scripts/test.sh`
  §4 compares "Expected" from `seed-anomalies.json` against "Captured" from a live run —
  see the root README's hard rule on never blurring the two) instead of hoping whatever
  real spend happened to occur during the build session would contain something
  detectable.
- **Every synthetic row carries `is_synthetic = true`**, the table is named
  `synthetic_billing_export` (not `gcp_billing_export_...`, the real export's naming
  convention), and the README, dashboard-adjacent docs and the architecture diagram all
  say **SYNTHETIC** next to it. Nothing in this repo claims this is live spend.
- **The trade-off is honesty about scope**: this proves the *detection method* works, not
  that it has ever caught a real anomaly in this project's actual spend. Pointing
  `SOURCE_TABLE` (a Cloud Run Job env var, set in `terraform/run.tf`) at a real detailed
  billing export table is a one-line config change — see
  [runbook 02](../runbooks/02-run-detection-and-inspect-results.md) — and nothing else
  in the architecture changes, because `main.py` only ever queries "a table shaped like a
  billing export," synthetic or real.
- A **known limitation** carried by using synthetic data: the injected anomalies are
  clean multiplicative spikes on top of realistic noise, which is easier for a z-score
  detector than a real-world anomaly buried in genuine seasonality (release trains,
  month-end batch jobs, regional failover). See the README's known-gaps section.
