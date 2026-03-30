resource "google_bigquery_dataset" "stock_history" {
  dataset_id = var.bq_dataset_id
  location   = "US"
}

resource "google_bigquery_table" "price_history" {
  dataset_id = google_bigquery_dataset.stock_history.dataset_id
  table_id   = "price_history"

  time_partitioning {
    type  = "DAY"
    field = "timestamp"
  }

  clustering = ["name"]

  # Duplicates are allowed — deduplication happens at query time via ROW_NUMBER() OVER (PARTITION BY event_id).
  # Note: FLOAT and FLOAT64 are aliases in BigQuery. Using FLOAT to match GCP's canonical representation.
  schema = jsonencode([
    { name = "name",           type = "STRING",    mode = "NULLABLE" },
    { name = "price",          type = "FLOAT",     mode = "NULLABLE" },
    { name = "timestamp",      type = "TIMESTAMP", mode = "NULLABLE" },
    { name = "operation_type", type = "STRING",    mode = "NULLABLE" },
    { name = "event_id",       type = "STRING",    mode = "NULLABLE" },
    { name = "ingested_at",    type = "TIMESTAMP", mode = "NULLABLE" }
  ])

  deletion_protection = false
}

resource "google_bigquery_table" "pipeline_metadata" {
  dataset_id = google_bigquery_dataset.stock_history.dataset_id
  table_id   = "pipeline_metadata"

  # Append-only. Read with: SELECT * FROM pipeline_metadata ORDER BY started_at DESC LIMIT 1
  time_partitioning {
    type  = "DAY"
    field = "started_at"
  }

  schema = jsonencode([
    { name = "pipeline_id",           type = "STRING",    mode = "NULLABLE" },
    { name = "started_at",            type = "TIMESTAMP", mode = "NULLABLE" },
    { name = "snapshot_completed_at", type = "TIMESTAMP", mode = "NULLABLE" },
    { name = "last_event_timestamp",  type = "TIMESTAMP", mode = "NULLABLE" },
    { name = "last_resume_token",     type = "STRING",    mode = "NULLABLE" },
    { name = "status",                type = "STRING",    mode = "NULLABLE" }
  ])

  deletion_protection = false
}
