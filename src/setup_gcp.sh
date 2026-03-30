#!/usr/bin/env bash
# Usage: bash setup_gcp.sh <your-gcp-project-id>
# Creates all GCP resources needed for the pipeline.
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

# 7. Create GCS bucket for resume tokens
BUCKET="${PROJECT_ID}-cdc-resume-tokens"
echo "==> Creating GCS bucket gs://${BUCKET} ..."
gcloud storage buckets create "gs://${BUCKET}" \
  --project="${PROJECT_ID}" \
  --location="US" \
  --uniform-bucket-level-access 2>/dev/null || echo "    (already exists, skipping)"

# 8. Create Pub/Sub topic
TOPIC="price-events"
echo "==> Creating Pub/Sub topic ${TOPIC} ..."
gcloud pubsub topics create "${TOPIC}" \
  --project="${PROJECT_ID}" 2>/dev/null || echo "    (already exists, skipping)"

# 9. Create dead letter topic
DLT="price-events-dead-letter"
echo "==> Creating dead letter topic ${DLT} ..."
gcloud pubsub topics create "${DLT}" \
  --project="${PROJECT_ID}" 2>/dev/null || echo "    (already exists, skipping)"

# 10. Create subscription with dead letter policy
SUB="price-events-sub"
echo "==> Creating subscription ${SUB} ..."
gcloud pubsub subscriptions create "${SUB}" \
  --project="${PROJECT_ID}" \
  --topic="${TOPIC}" \
  --ack-deadline=60 \
  --message-retention-duration=7d \
  --dead-letter-topic="projects/${PROJECT_ID}/topics/${DLT}" \
  --max-delivery-attempts=5 2>/dev/null || echo "    (already exists, skipping)"

# 11. Grant Pub/Sub + GCS IAM roles to service account
echo "==> Granting Pub/Sub and GCS roles ..."
for ROLE in roles/pubsub.publisher roles/pubsub.subscriber roles/storage.objectAdmin; do
  gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${SA_EMAIL}" \
    --role="${ROLE}" --quiet
done

# 12. Grant Pub/Sub service agent permissions for dead letter forwarding
PROJECT_NUMBER=$(gcloud projects describe "${PROJECT_ID}" --format="value(projectNumber)")
PUBSUB_SA="serviceAccount:service-${PROJECT_NUMBER}@gcp-sa-pubsub.iam.gserviceaccount.com"

gcloud pubsub topics add-iam-policy-binding "${DLT}" \
  --member="${PUBSUB_SA}" \
  --role="roles/pubsub.publisher" --quiet

gcloud pubsub subscriptions add-iam-policy-binding "${SUB}" \
  --member="${PUBSUB_SA}" \
  --role="roles/pubsub.subscriber" --quiet

echo ""
echo "Done. Next steps:"
echo "  1. Add to src/.env:"
echo "       GOOGLE_APPLICATION_CREDENTIALS=./service-account-key.json"
echo "       GCP_PROJECT_ID=${PROJECT_ID}"
echo "       BQ_DATASET=${DATASET}"
echo "       BQ_TABLE=${TABLE}"
echo "       BQ_METADATA_TABLE=${META_TABLE}"
echo "       PUBSUB_TOPIC=${TOPIC}"
echo "       PUBSUB_SUBSCRIPTION=${SUB}"
echo "       GCS_BUCKET=${BUCKET}"
echo "       GCS_RESUME_TOKEN_PATH=resume_token.txt"
echo "  2. pip install -r requirements.txt"
echo "  3. python subscriber.py   # terminal 1 — Pub/Sub to BigQuery"
echo "  4. python listener.py     # terminal 2 — CDC to Pub/Sub"
