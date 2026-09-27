# Live test results

Captured by `scripts/test.sh` on 2026-09-27T13:12:17Z against project `claude-code-507112` (europe-west1).

```

── 1. Topology ──
  PASS  BigQuery dataset exists  [claude-code-507112:finops ]
  PASS  source + results tables exist  [ tableId Type Labels Time Partitioning Clustered Fields -------------------------- ------- --------------------------------- ---------------]
  PASS  Cloud Run Job exists  [finops-anomaly-detector ]
  PASS  Cloud Scheduler job is ENABLED  [ENABLED ]
  PASS  Pub/Sub topic + subscription exist  [projects/claude-code-507112/topics/cost-anomalies ]

── 2. Synthetic seed data is clearly labelled, not live billing data ──
  PASS  source table has rows (seeded)  [720 ]
  PASS  every row is marked is_synthetic = true (0 exceptions)  [0 ]

── 3. Detection ran and wrote results ──
  PASS  at least one detector run has written to the anomalies table  [20260927T131203-7bc23b2d ]
    latest run_id: 20260927T131203-7bc23b2d  ·  rows flagged this run: 3

── 4. Anomaly correctness: Expected (ground truth) vs Captured (this run) ──
CAPTURED  Expected: 2026-08-19 Kubernetes Engine/Autopilot vCPU ns=checkout (x9.0) — runaway retry loop in a checkout batch job spiked GKE vCPU cost in the checkout namespace for one day
CAPTURED  Expected: 2026-09-03 BigQuery/Analysis ns=- (x12.0) — an unscheduled one-off backfill query scanned far more data than a normal day's analysis queries
CAPTURED  Expected: 2026-09-20 Kubernetes Engine/Autopilot Memory ns=checkout (x6.0) — a memory leak in a checkout service drove up GKE memory-request cost in the checkout namespace
SUMMARY  3/3 expected (synthetic, injected) anomalies were captured by this live run; 0 additional anomalies flagged beyond the injected set
  PASS  all 3 injected (synthetic) anomalies were captured  [CAPTURED  Expected: 2026-08-19 Kubernetes Engine/Autopilot vCPU ns=checkout (x9.0) — runaway retry loop in a checkout batch job spiked GKE]

── 5. Alerting: Pub/Sub delivery + log-based metric + alert policies ──
  PASS  an anomaly message is on the cost-anomalies subscription  [{"run_id": "20260927T131203-7bc23b2d", "detected_at": "2026-09-27T13:12:03.354882+00:00", "usage_date": "2026-08-19", "service_description":]
  PASS  log-based metric exists  [finops_anomalies_detected ]
  PASS  anomaly-detected alert policy exists  [FinOps: detector job execution failed FinOps: cost anomaly detected ]
  PASS  job-failed alert policy exists  [FinOps: detector job execution failed FinOps: cost anomaly detected ]
  PASS  dashboard exists  [FinOps cost-anomaly detector ]

── 6. Budget ──
  PASS  billing budget exists  [claude-code-507112 spend alert finops-cost-anomaly-detector ]

── 7. IAM least privilege ──
  PASS  finops-detector: no user-managed keys  [0 ]
  PASS  finops-scheduler: no user-managed keys  [0 ]
  PASS  finops-build: no user-managed keys  [0 ]
  PASS  finops-detector has no project-level owner/editor role  [absent: roles/owner|roles/editor]
  PASS  scheduler SA may invoke the job (job-scoped binding)  [['serviceAccount:finops-scheduler@claude-code-507112.iam.gserviceaccount.com'] ]
  PASS  job is not publicly invocable  [absent: allUsers]
```

**Result: 21 passed, 0 failed.**
