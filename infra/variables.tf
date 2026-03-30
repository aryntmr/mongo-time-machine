variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "region" {
  description = "GCP region for provider"
  type        = string
  default     = "us-central1"
}

variable "bq_dataset_id" {
  description = "BigQuery dataset ID"
  type        = string
  default     = "stock_history"
}

variable "pubsub_topic" {
  description = "Base name for the Pub/Sub topic (subscription and dead-letter topic are derived from this)"
  type        = string
  default     = "price-events"
}

variable "gar_location" {
  description = "Artifact Registry location — must be a single region (e.g. us-central1)"
  type        = string
  default     = "us-central1"
}

variable "gce_zone" {
  description = "GCE zone for the listener VM (e.g. us-central1-a)"
  type        = string
  default     = "us-central1-a"
}

variable "cloudrun_region" {
  description = "Cloud Run region for the subscriber service"
  type        = string
  default     = "us-central1"
}
