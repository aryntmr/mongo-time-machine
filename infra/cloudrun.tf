resource "google_cloud_run_v2_service" "subscriber" {
  name     = "vali-subscriber"
  location = var.cloudrun_region

  template {
    service_account = google_service_account.pipeline.email

    scaling {
      min_instance_count = 1
      max_instance_count = 10
    }

    containers {
      # Placeholder image — replaced by deploy.sh on first real deploy.
      # lifecycle.ignore_changes below prevents terraform apply from
      # reverting this back to the placeholder after deploy.sh updates it.
      image = "us-docker.pkg.dev/cloudrun/container/hello"

      env {
        name  = "GCP_PROJECT_ID"
        value = var.project_id
      }
      env {
        name  = "BQ_DATASET"
        value = var.bq_dataset_id
      }
      env {
        name  = "BQ_TABLE"
        value = "price_history"
      }
      env {
        name  = "BQ_METADATA_TABLE"
        value = "pipeline_metadata"
      }
      env {
        name  = "PUBSUB_TOPIC"
        value = var.pubsub_topic
      }
      env {
        name  = "PUBSUB_SUBSCRIPTION"
        value = "${var.pubsub_topic}-sub"
      }
      env {
        name  = "GCS_BUCKET"
        value = "${var.project_id}-cdc-resume-tokens"
      }
    }
  }

  lifecycle {
    # Prevent terraform apply from reverting the image back to the placeholder
    # after deploy.sh deploys the real subscriber image.
    ignore_changes = [template[0].containers[0].image]
  }
}
