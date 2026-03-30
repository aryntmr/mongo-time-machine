#!/usr/bin/env bash
# deploy.sh — build, push, and deploy pipeline services to GCP
#
# Default: subscriber to Cloud Run only (listener runs locally as a Docker container).
#
# Usage:
#   bash deploy.sh                   # subscriber to Cloud Run (default)
#   bash deploy.sh --subscriber-only # same as default, explicit
#   bash deploy.sh --listener-only   # listener to GCE only (production/optional)
#   bash deploy.sh --all             # both listener (GCE) + subscriber (Cloud Run)
#
# Prerequisites:
#   - bootstrap.sh has been run (GCP infra provisioned, .env populated)
#   - Docker is running
#   - gcloud is authenticated (gcloud auth login)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="${SCRIPT_DIR}/../infra"

# ── parse flags ────────────────────────────────────────────────────────────────

# Listener runs locally by default — GCE deployment is opt-in.
DEPLOY_LISTENER=false
DEPLOY_SUBSCRIBER=true

for arg in "$@"; do
  case "$arg" in
    --subscriber-only) DEPLOY_LISTENER=false;  DEPLOY_SUBSCRIBER=true ;;
    --listener-only)   DEPLOY_LISTENER=true;   DEPLOY_SUBSCRIBER=false ;;
    --all)             DEPLOY_LISTENER=true;   DEPLOY_SUBSCRIBER=true ;;
    --help|-h)
      echo "Usage: bash deploy.sh [--subscriber-only | --listener-only | --all]"
      echo "  (default: subscriber to Cloud Run only)"
      exit 0
      ;;
  esac
done

# ── helpers ────────────────────────────────────────────────────────────────────

log()  { echo ""; echo "==> $*"; }
info() { echo "    $*"; }
die()  { echo ""; echo "[error] $*" >&2; exit 1; }

# ── validate prerequisites ─────────────────────────────────────────────────────

log "Checking prerequisites ..."

[[ -f "${SCRIPT_DIR}/.env" ]] || die ".env not found. Run bootstrap.sh first."
command -v docker   &>/dev/null || die "Docker not found or not running."
command -v gcloud   &>/dev/null || die "gcloud CLI not found."
command -v terraform &>/dev/null || die "Terraform not found. It's needed to read output values."

# ── load config ────────────────────────────────────────────────────────────────

log "Loading config from .env and Terraform outputs ..."

# shellcheck disable=SC1091
source "${SCRIPT_DIR}/.env"

GAR_REPO=$(terraform -chdir="$INFRA_DIR" output -raw gar_repository)
GAR_REGION="${GAR_LOCATION:-us-central1}"
GCE_INSTANCE=$(terraform -chdir="$INFRA_DIR" output -raw gce_instance_name)
GCE_ZONE="${GCE_ZONE:-us-central1-a}"
CLOUDRUN_REGION="${CLOUDRUN_REGION:-us-central1}"
SA_EMAIL=$(terraform -chdir="$INFRA_DIR" output -raw service_account_email)

LISTENER_IMAGE="${GAR_REPO}/listener:latest"
SUBSCRIBER_IMAGE="${GAR_REPO}/subscriber:latest"

info "GAR repository : ${GAR_REPO}"
info "Cloud Run      : vali-subscriber (${CLOUDRUN_REGION})"
if $DEPLOY_LISTENER; then
  info "GCE instance   : ${GCE_INSTANCE} (${GCE_ZONE})"
fi

# ── configure Docker for Artifact Registry ─────────────────────────────────────

log "Configuring Docker credential helper for GAR ..."
gcloud auth configure-docker "${GAR_REGION}-docker.pkg.dev" --quiet
info "Docker configured for ${GAR_REGION}-docker.pkg.dev"

cd "$SCRIPT_DIR"

# ── listener: build → push → update GCE ───────────────────────────────────────

if $DEPLOY_LISTENER; then
  log "Building and pushing listener image (linux/amd64) ..."
  docker buildx build --platform linux/amd64 --push -t "$LISTENER_IMAGE" -f Dockerfile.listener .
  info "Build + push complete: ${LISTENER_IMAGE}"

  log "Writing listener config to GCE instance metadata ..."
  gcloud compute instances add-metadata "$GCE_INSTANCE" \
    --zone="$GCE_ZONE" \
    --metadata=\
"gcp-project-id=${GCP_PROJECT_ID},\
gar-region=${GAR_REGION},\
bq-dataset=${BQ_DATASET},\
bq-table=${BQ_TABLE},\
bq-metadata-table=${BQ_METADATA_TABLE},\
pubsub-topic=${PUBSUB_TOPIC},\
gcs-bucket=${GCS_BUCKET},\
gcs-resume-token-path=${GCS_RESUME_TOKEN_PATH},\
mongo-uri=${MONGO_URI},\
db-name=${DB_NAME},\
collection=${COLLECTION}"
  info "Metadata updated"

  log "Resetting GCE VM to pull new image and restart listener ..."
  gcloud compute instances reset "$GCE_INSTANCE" \
    --zone="$GCE_ZONE" \
    --quiet
  info "VM reset issued. Startup script will pull the image and start the container (~60s)."
  info "Resume token is safely persisted in GCS — no data loss on restart."
fi

# ── subscriber: build → push → Cloud Run deploy ───────────────────────────────

if $DEPLOY_SUBSCRIBER; then
  log "Building and pushing subscriber image (linux/amd64) ..."
  docker buildx build --platform linux/amd64 --push -t "$SUBSCRIBER_IMAGE" -f Dockerfile.subscriber .
  info "Build + push complete: ${SUBSCRIBER_IMAGE}"

  log "Deploying subscriber to Cloud Run ..."
  gcloud run deploy vali-subscriber \
    --image="$SUBSCRIBER_IMAGE" \
    --region="$CLOUDRUN_REGION" \
    --platform=managed \
    --no-allow-unauthenticated \
    --service-account="$SA_EMAIL" \
    --min-instances=1 \
    --max-instances=10 \
    --set-env-vars="\
GCP_PROJECT_ID=${GCP_PROJECT_ID},\
BQ_DATASET=${BQ_DATASET},\
BQ_TABLE=${BQ_TABLE},\
BQ_METADATA_TABLE=${BQ_METADATA_TABLE},\
PUBSUB_TOPIC=${PUBSUB_TOPIC},\
PUBSUB_SUBSCRIPTION=${PUBSUB_SUBSCRIPTION},\
GCS_BUCKET=${GCS_BUCKET}" \
    --quiet
  info "Cloud Run deploy complete (zero-downtime rollout)"
fi

# ── done ───────────────────────────────────────────────────────────────────────

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Deploy complete."
echo ""
if $DEPLOY_SUBSCRIBER; then
  echo "  Subscriber logs (Cloud Run):"
  echo "    gcloud logging read \"resource.type=cloud_run_revision AND resource.labels.service_name=vali-subscriber\" --limit=50 --format='value(textPayload)'"
fi
if $DEPLOY_LISTENER; then
  echo "  Listener logs (GCE — wait ~60s for VM startup):"
  echo "    gcloud compute ssh ${GCE_INSTANCE} --zone=${GCE_ZONE} -- 'docker logs vali-listener'"
else
  echo "  Listener: running locally via Docker."
  echo "    make listener-up    # start listener container (connects to local MongoDB)"
  echo "    docker logs -f vali-listener"
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
