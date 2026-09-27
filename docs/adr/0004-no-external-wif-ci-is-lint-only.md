# ADR 0004 — No GitHub-Actions-to-GCP WIF in this repo; CI is lint/validate/scan only

**Status:** accepted

Two sibling repos in this project (`gcp-gke-platform-engineering`,
`gcp-enterprise-rag-platform`) set up Workload Identity Federation so GitHub Actions can
authenticate to GCP without a service-account key — for a `terraform plan` on pull
requests, and, in one case, a gated deploy job. That pattern was considered here and
deliberately **not** carried over, for a narrower reason than "it wasn't needed":

- This repo's whole point is that **one script, run by a person with `gcloud` already
  authenticated, builds and tears down the stack** (`scripts/up.sh` / `scripts/down.sh`).
  There is no CI-triggered deploy step for WIF to authenticate *into* — CI here only
  needs to validate the Terraform and Python **without ever touching the live project**
  (`.github/workflows/ci.yml`: `terraform validate` with `-backend=false`, `ruff`,
  `pytest`, a Trivy config scan, and a determinism check that regenerating the synthetic
  seed data byte-matches what's checked in). None of that needs GCP credentials of any
  kind, federated or otherwise.
- Setting up a WIF pool for CI anyway, with nothing for it to do, would be exactly the
  kind of unused-but-present IAM surface the threat model argues against elsewhere in
  this repo (see [threat model](../threat-model.md)) — a broader attack surface for no
  proven benefit. It would also collide with the other repos' 30-day pool-name reuse
  restriction for no reason, since this repo has no KMS key ring or WIF pool to protect
  from that restriction in the first place.

**What "no service-account keys" still means here without WIF for CI:** the Cloud Run
Job, Cloud Scheduler and Cloud Build all authenticate as **attached Google-managed
service accounts** (ADC) — the mechanism WIF exists to replace for *external* identities
like GitHub Actions. Nothing in this repo has, or needs, a downloaded key file.

**Known gap:** if this repo ever grows a CI-triggered deploy job (e.g. auto-`plan` a real
project on PRs), that job should reuse the WIF pattern already proven in
`gcp-gke-platform-engineering`'s `terraform/modules/github_wif`, not reinvent it.
