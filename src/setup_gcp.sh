#!/usr/bin/env bash
# Usage: bash setup_gcp.sh <your-gcp-project-id>
# Creates all GCP resources needed for Version 1 of the pipeline.
# Run once. Safe to re-run — most gcloud commands are idempotent.

set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: bash setup_gcp.sh <gcp-project-id>"
  exit 1
fi

PROJECT_ID="$1"
SA_NAME="vali-pipeline"
SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
KEY_FILE="./service-account-key.json"
DATASET="stock_history"
TABLE="price_history"
META_TABLE="pipeline_metadata"

echo "==> Project: ${PROJECT_ID}"

# 1. Create service account (ignore error if it already exists)
echo "==> Creating service account ${SA_NAME} ..."
gcloud iam service-accounts create "${SA_NAME}" \
  --display-name="Vali Pipeline SA" \
  --project="${PROJECT_ID}" 2>/dev/null || echo "    (already exists, skipping)"

# 2. Grant least-privilege IAM roles
echo "==> Granting BigQuery roles ..."
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="roles/bigquery.dataEditor"

gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="roles/bigquery.jobUser"

# 3. Download service account key (skip if already present — re-run safe)
if [[ -f "${KEY_FILE}" ]] && [[ -s "${KEY_FILE}" ]]; then
  echo "    (${KEY_FILE} already exists, skipping)"
else
  echo "==> Downloading key to ${KEY_FILE} ..."
  gcloud iam service-accounts keys create "${KEY_FILE}" \
    --iam-account="${SA_EMAIL}" \
    --project="${PROJECT_ID}"
fi

# 4. Create BigQuery dataset
echo "==> Creating dataset ${DATASET} ..."
bq --project_id="${PROJECT_ID}" mk --dataset "${DATASET}" 2>/dev/null || echo "    (already exists, skipping)"

# 5. Create price_history table with schema, partitioned + clustered
echo "==> Creating table ${DATASET}.${TABLE} ..."
bq mk --table \
  --time_partitioning_field=timestamp \
  --time_partitioning_type=DAY \
  --clustering_fields=name \
  --schema='name:STRING,price:FLOAT64,timestamp:TIMESTAMP,operation_type:STRING,event_id:STRING,ingested_at:TIMESTAMP' \
  "${PROJECT_ID}:${DATASET}.${TABLE}" 2>/dev/null || echo "    (already exists, skipping)"

# 6. Create pipeline_metadata table
echo "==> Creating table ${DATASET}.${META_TABLE} ..."
bq mk --table \
  --time_partitioning_type=DAY \
  --time_partitioning_field=started_at \
  "${PROJECT_ID}:${DATASET}.${META_TABLE}" \
  'pipeline_id:STRING,started_at:TIMESTAMP,snapshot_completed_at:TIMESTAMP,last_event_timestamp:TIMESTAMP,last_resume_token:STRING,status:STRING' \
  2>/dev/null || echo "    (already exists, skipping)"

echo ""
echo "Done. Next steps:"
echo "  1. Add to src/.env:"
echo "       GOOGLE_APPLICATION_CREDENTIALS=./service-account-key.json"
echo "       GCP_PROJECT_ID=${PROJECT_ID}"
echo "       BQ_DATASET=${DATASET}"
echo "       BQ_TABLE=${TABLE}"
echo "       BQ_METADATA_TABLE=${META_TABLE}"
echo "  2. pip install -r requirements.txt"
echo "  3. python listener.py"
