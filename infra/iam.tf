resource "google_service_account" "pipeline" {
  account_id   = "vali-pipeline"
  display_name = "Vali Pipeline Service Account"
}

# Least-privilege roles required by listener.py, subscriber.py, query.py, validate.py.
locals {
  pipeline_roles = toset([
    "roles/bigquery.dataEditor",
    "roles/bigquery.jobUser",
    "roles/pubsub.publisher",
    "roles/pubsub.subscriber",
    "roles/storage.objectAdmin",
    "roles/artifactregistry.reader", # pull images from GAR on GCE and Cloud Run
  ])
}

resource "google_project_iam_member" "pipeline" {
  for_each = local.pipeline_roles

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.pipeline.email}"
}

# ── Pub/Sub service agent permissions for dead-letter forwarding ───────────────
# The Pub/Sub service agent needs publisher rights on the dead-letter topic
# and subscriber rights on the source subscription to forward failed messages.
data "google_project" "current" {}

locals {
  pubsub_sa = "serviceAccount:service-${data.google_project.current.number}@gcp-sa-pubsub.iam.gserviceaccount.com"
}

resource "google_pubsub_topic_iam_member" "dead_letter_publisher" {
  topic  = google_pubsub_topic.price_events_dead_letter.name
  role   = "roles/pubsub.publisher"
  member = local.pubsub_sa
}

resource "google_pubsub_subscription_iam_member" "dead_letter_subscriber" {
  subscription = google_pubsub_subscription.price_events_sub.name
  role         = "roles/pubsub.subscriber"
  member       = local.pubsub_sa
}

# ── Service account key ────────────────────────────────────────────────────────
resource "google_service_account_key" "pipeline" {
  service_account_id = google_service_account.pipeline.name
}
