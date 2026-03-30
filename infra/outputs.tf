output "service_account_email" {
  description = "Email of the pipeline service account"
  value       = google_service_account.pipeline.email
}

output "gcs_bucket_name" {
  description = "GCS bucket name for resume token storage"
  value       = google_storage_bucket.resume_tokens.name
}

output "pubsub_topic" {
  description = "Pub/Sub topic name for price events"
  value       = google_pubsub_topic.price_events.name
}

output "pubsub_subscription" {
  description = "Pub/Sub subscription name"
  value       = google_pubsub_subscription.price_events_sub.name
}

output "bq_dataset" {
  description = "BigQuery dataset ID"
  value       = google_bigquery_dataset.stock_history.dataset_id
}
