#!/usr/bin/env bash
# bootstrap.sh — one-command setup for the Vali Health CDC pipeline
#
# Usage:
#   bash bootstrap.sh [gcp-project-id]
#
# What this does (safe to re-run — all steps are idempotent):
#   1. Verifies gcloud CLI is installed
#   2. Authenticates with GCP (opens browser once, skips if already logged in)
#   3. Enables BigQuery, Pub/Sub, and Storage APIs on the project
#   4. Creates GCP resources: service account, IAM roles, BQ dataset + tables, Pub/Sub topics + subscription, GCS bucket
#   5. Writes GCP config vars to .env (never overwrites existing Mongo vars)
#   6. Installs Python dependencies

set -euo pipefail

# ── helpers ────────────────────────────────────────────────────────────────────

log()  { echo ""; echo "==> $*"; }
info() { echo "    $*"; }
die()  { echo ""; echo "[error] $*" >&2; exit 1; }

# Adds or updates a single KEY=VALUE line in .env without touching other lines.
set_env_var() {
  local key="$1" value="$2" file=".env"
  if grep -q "^${key}=" "${file}" 2>/dev/null; then
    sed -i.bak "s|^${key}=.*|${key}=${value}|" "${file}" && rm -f "${file}.bak"
  else
    echo "${key}=${value}" >> "${file}"
  fi
}

# ── 1. check gcloud ────────────────────────────────────────────────────────────

log "Checking gcloud CLI ..."
if ! command -v gcloud &>/dev/null; then
  die "gcloud CLI not found. Install it from https://cloud.google.com/sdk/docs/install then re-run this script."
fi
info "Found: $(gcloud version 2>/dev/null | head -1)"

# ── 2. authenticate ────────────────────────────────────────────────────────────

log "Checking GCP authentication ..."
ACTIVE_ACCOUNT=$(gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null | head -1)

if [[ -z "${ACTIVE_ACCOUNT}" ]]; then
  info "No active account found. Opening browser for login ..."
  gcloud auth login
  ACTIVE_ACCOUNT=$(gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null | head -1)
  [[ -z "${ACTIVE_ACCOUNT}" ]] && die "Authentication failed. Run 'gcloud auth login' manually and retry."
fi
info "Authenticated as: ${ACTIVE_ACCOUNT}"

# ── 3. resolve project ID ──────────────────────────────────────────────────────

log "Resolving GCP project ..."

PROJECT_ID="${1:-}"

# Fall back to value already in .env
if [[ -z "${PROJECT_ID}" ]]; then
  PROJECT_ID=$(grep "^GCP_PROJECT_ID=" .env 2>/dev/null | cut -d'=' -f2 || true)
fi

# Last resort: prompt the user
if [[ -z "${PROJECT_ID}" ]]; then
  read -rp "    Enter your GCP project ID: " PROJECT_ID
fi

[[ -z "${PROJECT_ID}" ]] && die "No GCP project ID provided."

gcloud config set project "${PROJECT_ID}" --quiet
info "Using project: ${PROJECT_ID}"

# ── 4. enable BigQuery API ─────────────────────────────────────────────────────

log "Enabling GCP APIs ..."
gcloud services enable bigquery.googleapis.com --project="${PROJECT_ID}" --quiet
info "bigquery.googleapis.com enabled"
gcloud services enable pubsub.googleapis.com --project="${PROJECT_ID}" --quiet
info "pubsub.googleapis.com enabled"
gcloud services enable storage.googleapis.com --project="${PROJECT_ID}" --quiet
info "storage.googleapis.com enabled"

# ── 5. provision GCP resources ─────────────────────────────────────────────────

log "Provisioning GCP resources ..."
bash "$(dirname "$0")/setup_gcp.sh" "${PROJECT_ID}"

# ── 6. write GCP vars to .env ──────────────────────────────────────────────────

log "Updating .env ..."
if [[ ! -f ".env" ]]; then
  cp .env.example .env
  info ".env created from .env.example — verify MONGO_URI and other Mongo settings."
fi

set_env_var "GOOGLE_APPLICATION_CREDENTIALS" "./service-account-key.json"
set_env_var "GCP_PROJECT_ID"                 "${PROJECT_ID}"
set_env_var "BQ_DATASET"                     "stock_history"
set_env_var "BQ_TABLE"                       "price_history"
set_env_var "BQ_METADATA_TABLE"              "pipeline_metadata"
set_env_var "PUBSUB_TOPIC"                   "price-events"
set_env_var "PUBSUB_SUBSCRIPTION"            "price-events-sub"
set_env_var "GCS_BUCKET"                     "${PROJECT_ID}-cdc-resume-tokens"
set_env_var "GCS_RESUME_TOKEN_PATH"          "resume_token.txt"

info ".env updated with GCP vars"

# ── 7. install Python dependencies ─────────────────────────────────────────────

log "Installing Python dependencies ..."
PYTHON=$(command -v python3 || command -v python)
[[ -z "${PYTHON}" ]] && die "python not found. Activate your venv first: source .venv/bin/activate"
"${PYTHON}" -m pip install -r requirements.txt --quiet
info "Dependencies installed"

# ── done ───────────────────────────────────────────────────────────────────────

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Setup complete."
echo ""
echo "  To run the pipeline:"
echo "    make up                               # start MongoDB replica set"
echo "    make subscribe                        # terminal 1 — Pub/Sub to BigQuery"
echo "    make listen                           # terminal 2 — CDC to Pub/Sub"
echo "    make simulate                         # terminal 3 — price updates"
echo ""
echo "  To query BigQuery:"
echo "    python query.py --name AAPL --latest"
echo "    python query.py --name AAPL --time '2026-03-29 12:00:00'"
echo "    python query.py --all-at-time '2026-03-29 12:00:00'"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
