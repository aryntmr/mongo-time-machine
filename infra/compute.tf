resource "google_compute_instance" "listener" {
  name         = "vali-listener"
  machine_type = "e2-micro"
  zone         = var.gce_zone

  boot_disk {
    initialize_params {
      image = "projects/cos-cloud/global/images/family/cos-stable"
      size  = 10
      type  = "pd-balanced"
    }
  }

  network_interface {
    network = "default"
    access_config {} # ephemeral public IP — needed to pull from GAR and reach GCP APIs
  }

  service_account {
    email  = google_service_account.pipeline.email
    scopes = ["https://www.googleapis.com/auth/cloud-platform"]
  }

  # Startup script runs on every boot (including after deploy.sh resets the VM).
  # It reads all runtime config from instance metadata keys set by deploy.sh,
  # then pulls the latest listener image and starts the container.
  #
  # First-deploy behavior: on initial terraform apply, the image does not yet exist
  # in GAR. The docker pull will fail gracefully, and the VM runs without a container.
  # After deploy.sh pushes the image, it calls `gcloud compute instances reset`
  # which re-runs this script successfully.
  #
  # Note: bash ${VAR} is written as $${VAR} here so Terraform does not attempt to
  # interpolate it as a template expression. The actual startup script received by
  # the VM will contain ${VAR} as expected by bash.
  metadata = {
    startup-script = <<-EOT
      #!/bin/bash
      METADATA_URL="http://metadata.google.internal/computeMetadata/v1/instance/attributes"
      H="Metadata-Flavor: Google"
      get_meta() { curl -sf -H "$H" "$METADATA_URL/$1" || echo ""; }

      GCP_PROJECT_ID=$(get_meta gcp-project-id)
      GAR_REGION=$(get_meta gar-region)

      if [[ -z "$GCP_PROJECT_ID" || -z "$GAR_REGION" ]]; then
        echo "[startup] Metadata not set yet — run deploy.sh to configure and restart."
        exit 0
      fi

      IMAGE="$GAR_REGION-docker.pkg.dev/$GCP_PROJECT_ID/vali-pipeline/listener:latest"

      # Authenticate Docker to GAR using the attached service account identity
      docker-credential-gcr configure-docker --registries="$GAR_REGION-docker.pkg.dev"

      if ! docker pull "$IMAGE"; then
        echo "[startup] Image not found in GAR — run 'make deploy' to build and push."
        exit 0
      fi

      docker stop vali-listener 2>/dev/null || true
      docker rm   vali-listener 2>/dev/null || true

      docker run -d --name vali-listener \
        --restart unless-stopped \
        --log-driver=gcplogs \
        -e GCP_PROJECT_ID="$(get_meta gcp-project-id)" \
        -e BQ_DATASET="$(get_meta bq-dataset)" \
        -e BQ_TABLE="$(get_meta bq-table)" \
        -e BQ_METADATA_TABLE="$(get_meta bq-metadata-table)" \
        -e PUBSUB_TOPIC="$(get_meta pubsub-topic)" \
        -e GCS_BUCKET="$(get_meta gcs-bucket)" \
        -e GCS_RESUME_TOKEN_PATH="$(get_meta gcs-resume-token-path)" \
        -e MONGO_URI="$(get_meta mongo-uri)" \
        -e DB_NAME="$(get_meta db-name)" \
        -e COLLECTION="$(get_meta collection)" \
        "$IMAGE"

      echo "[startup] vali-listener started."
    EOT
  }

  # Allow Terraform to stop the VM when updating metadata or machine type.
  allow_stopping_for_update = true

  depends_on = [google_artifact_registry_repository.vali_pipeline]

  tags = ["vali-listener"]
}
