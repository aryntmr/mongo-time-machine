resource "google_storage_bucket" "resume_tokens" {
  name     = "${var.project_id}-cdc-resume-tokens"
  location = "US"

  uniform_bucket_level_access = true

  # Required for terraform destroy to succeed when the pipeline has written
  # a resume token object to the bucket.
  force_destroy = true

  # Versioning lets us recover a previously valid resume token if the current
  # one is accidentally overwritten or corrupted.
  versioning {
    enabled = true
  }
}
