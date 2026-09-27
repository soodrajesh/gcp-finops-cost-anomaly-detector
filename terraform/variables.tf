variable "project_id" {
  type = string
}

variable "region" {
  type    = string
  default = "europe-west1"
}

variable "billing_account_id" {
  type = string
}

variable "budget_amount" {
  description = "Monthly budget in EUR that triggers Billing Budget alerts."
  type        = number
  default     = 15
}

variable "alert_email" {
  type = string
}

variable "admin_email" {
  type = string
}

variable "image" {
  description = "Digest-pinned container image for the detector Cloud Run Job. Empty = phase 1 (infrastructure only, job not yet created)."
  type        = string
  default     = ""
}

variable "z_threshold" {
  description = "Standard deviations from the trailing baseline before a day is flagged an anomaly."
  type        = number
  default     = 3.5
}

variable "baseline_days" {
  description = "Trailing window (days) used to compute the mean/stddev baseline for each series."
  type        = number
  default     = 14
}

variable "schedule_cron" {
  description = "Cloud Scheduler cron expression for the daily detection run."
  type        = string
  default     = "0 6 * * *"
}
