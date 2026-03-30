resource "google_artifact_registry_repository" "vali_pipeline" {
  repository_id = "vali-pipeline"
  location      = var.gar_location
  format        = "DOCKER"
  description   = "Container images for the Vali Health CDC pipeline"

  cleanup_policies {
    id     = "keep-last-10"
    action = "KEEP"
    most_recent_versions {
      keep_count = 10
    }
  }
}
