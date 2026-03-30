output "service_account_email" {
  description = "Email of the pipeline service account"
  value       = google_service_account.pipeline.email
}

output "service_account_key_json" {
  description = "Service account key JSON — written to src/service-account-key.json by bootstrap.sh"
  value       = base64decode(google_service_account_key.pipeline.private_key)
  sensitive   = true
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

output "gar_repository" {
  description = "Full GAR repository hostname used as image prefix in Docker commands"
  value       = "${var.gar_location}-docker.pkg.dev/${var.project_id}/vali-pipeline"
}

output "gce_instance_name" {
  description = "GCE instance name for the listener VM"
  value       = google_compute_instance.listener.name
}

output "cloudrun_service_url" {
  description = "Cloud Run service URL for the subscriber"
  value       = google_cloud_run_v2_service.subscriber.uri
}
