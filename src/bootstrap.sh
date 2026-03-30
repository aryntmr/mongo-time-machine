#!/usr/bin/env bash
# bootstrap.sh — one-command setup for the Vali Health CDC pipeline
#
# Usage:
#   bash bootstrap.sh [gcp-project-id]
#
# If config.yaml is present (copied from config.yaml.example and filled in),
# it takes precedence over the CLI argument and existing .env values.
#
# What this does (safe to re-run — all steps are idempotent):
#   1.   Verifies gcloud CLI is installed
#   2.   Authenticates with GCP (opens browser once, skips if already logged in)
#   2.5  Sets up Application Default Credentials for Terraform (separate from gcloud login)
#   3.   Reads config.yaml if present
#   4.   Resolves GCP project ID (config.yaml > CLI arg > .env > prompt)
#   5.   Enables BigQuery, Pub/Sub, Storage, IAM, and Cloud Resource Manager APIs
#   6.   Provisions GCP resources via Terraform (falls back to setup_gcp.sh)
#   7.   Writes GCP + MongoDB vars to .env
#   8.   Installs Python dependencies

set -euo pipefail

# ── helpers ────────────────────────────────────────────────────────────────────

log()  { echo ""; echo "==> $*"; }
info() { echo "    $*"; }
die()  { echo ""; echo "[error] $*" >&2; exit 1; }

# Adds or updates a single KEY=VALUE line in .env without touching other lines.
set_env_var() {
  local key="$1" value="$2" file=".env"
  if grep -q "^${key}=" "${file}" 2>/dev/null; then
    # Escape & in the replacement string — sed treats & as "the matched string".
    # This matters for values like MongoDB Atlas URIs that contain & query params.
    local escaped="${value//&/\\&}"
    sed -i.bak "s|^${key}=.*|${key}=${escaped}|" "${file}" && rm -f "${file}.bak"
  else
    echo "${key}=${value}" >> "${file}"
  fi
}

# Reads a dotted key from config.yaml using Python (e.g., "gcp.project_id").
# Booleans are lowercased so .env values match the .env.example convention (true/false).
yaml_get() {
  local key="$1"
  python3 -c "
import yaml
keys = '${key}'.split('.')
c = yaml.safe_load(open('config.yaml'))
for k in keys:
    c = c[k]
print('' if c is None else str(c).lower() if isinstance(c, bool) else c)
" 2>/dev/null || true
}

# ── 1. check gcloud ────────────────────────────────────────────────────────────

log "Checking gcloud CLI ..."
if ! command -v gcloud &>/dev/null; then
  die "gcloud CLI not found. Run this script via 'make bootstrap' (uses the tools container)."
fi
info "Found: $(gcloud version 2>/dev/null | head -1)"

# ── 2. authenticate ────────────────────────────────────────────────────────────
# --no-launch-browser: prints a URL instead of trying to open a browser.
# Works in Docker containers and SSH sessions. Credentials are written to
# ~/.config/gcloud which is volume-mounted and persists across container runs.

log "Checking GCP authentication ..."
ACTIVE_ACCOUNT=$(gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null | head -1)

if [[ -z "${ACTIVE_ACCOUNT}" ]]; then
  info "No active account found. Follow the link below to authenticate."
  gcloud auth login --no-launch-browser
  ACTIVE_ACCOUNT=$(gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null | head -1)
  [[ -z "${ACTIVE_ACCOUNT}" ]] && die "Authentication failed. Re-run 'make bootstrap'."
fi
info "Authenticated as: ${ACTIVE_ACCOUNT}"

# ── 2.5 application-default credentials (required by Terraform) ────────────────
# gcloud auth login sets the gcloud identity but does NOT configure ADC.
# Terraform's Google provider uses ADC — without it, terraform apply fails with
# "could not find default credentials".

log "Checking Application Default Credentials (ADC) ..."
if ! gcloud auth application-default print-access-token &>/dev/null; then
  info "No ADC found. Follow the link below to set up Application Default Credentials."
  gcloud auth application-default login --no-launch-browser
fi
info "ADC configured"

# ── 3. parse config.yaml ───────────────────────────────────────────────────────

YAML_PROJECT=""
YAML_REGION=""
YAML_MONGO=""
YAML_DB=""
YAML_COL=""
YAML_UPDATE_INTERVAL=""
YAML_BURSTY_MODE=""
YAML_BURSTY_MIN=""
YAML_BURSTY_MAX=""

if [[ -f "config.yaml" ]]; then
  # Ensure pyyaml is available before parsing. On a fresh venv (no packages yet),
  # yaml_get would silently return empty strings — user's config.yaml values ignored.
  if ! python3 -c "import yaml" 2>/dev/null; then
    info "Installing pyyaml for config.yaml parsing ..."
    python3 -m pip install pyyaml --quiet \
      || die "pyyaml install failed. Activate your venv first: source .venv/bin/activate"
  fi

  log "Reading config.yaml ..."
  YAML_PROJECT=$(yaml_get "gcp.project_id")
  YAML_REGION=$(yaml_get "gcp.region")
  YAML_MONGO=$(yaml_get "mongodb.connection_string")
  YAML_DB=$(yaml_get "mongodb.database")
  YAML_COL=$(yaml_get "mongodb.collection")
  YAML_UPDATE_INTERVAL=$(yaml_get "pipeline.update_interval")
  YAML_BURSTY_MODE=$(yaml_get "pipeline.bursty_mode")
  YAML_BURSTY_MIN=$(yaml_get "pipeline.bursty_min")
  YAML_BURSTY_MAX=$(yaml_get "pipeline.bursty_max")
  info "Loaded config from config.yaml"
else
  info "config.yaml not found — using CLI args / .env / prompts"
fi

# ── 4. resolve project ID ──────────────────────────────────────────────────────

log "Resolving GCP project ..."

# Priority: config.yaml > CLI arg > existing .env > prompt
PROJECT_ID="${YAML_PROJECT:-${1:-}}"

if [[ -z "${PROJECT_ID}" ]]; then
  PROJECT_ID=$(grep "^GCP_PROJECT_ID=" .env 2>/dev/null | cut -d'=' -f2 || true)
fi

if [[ -z "${PROJECT_ID}" ]]; then
  read -rp "    Enter your GCP project ID: " PROJECT_ID
fi

[[ -z "${PROJECT_ID}" ]] && die "No GCP project ID provided."

# Reject unfilled placeholder
[[ "${PROJECT_ID}" == "<GCP_PROJECT_ID>" ]] && die "Replace <GCP_PROJECT_ID> in config.yaml with your actual project ID."

gcloud config set project "${PROJECT_ID}" --quiet
info "Using project: ${PROJECT_ID}"

# Verify the active account can access this project. If not, re-authenticate.
# This handles switching to a different GCP account without requiring the user
# to manually run gcloud auth login first.
if ! gcloud projects describe "${PROJECT_ID}" --quiet &>/dev/null; then
  info "Account ${ACTIVE_ACCOUNT} cannot access project ${PROJECT_ID}."
  info "Please authenticate with the account that owns this project."
  gcloud auth login --no-launch-browser
  ACTIVE_ACCOUNT=$(gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null | head -1)
  [[ -z "${ACTIVE_ACCOUNT}" ]] && die "Authentication failed. Re-run 'make bootstrap'."
  gcloud config set project "${PROJECT_ID}" --quiet
  info "Authenticated as: ${ACTIVE_ACCOUNT}"
  # ADC must also be refreshed for the new account — Terraform uses ADC, not gcloud auth.
  info "Refreshing Application Default Credentials for new account ..."
  gcloud auth application-default login --no-launch-browser
fi

REGION="${YAML_REGION:-us-central1}"

# ── 5. enable GCP APIs ─────────────────────────────────────────────────────────

log "Enabling GCP APIs ..."
gcloud services enable bigquery.googleapis.com --project="${PROJECT_ID}" --quiet
info "bigquery.googleapis.com enabled"
gcloud services enable pubsub.googleapis.com --project="${PROJECT_ID}" --quiet
info "pubsub.googleapis.com enabled"
gcloud services enable storage.googleapis.com --project="${PROJECT_ID}" --quiet
info "storage.googleapis.com enabled"
gcloud services enable iam.googleapis.com --project="${PROJECT_ID}" --quiet
info "iam.googleapis.com enabled"
gcloud services enable cloudresourcemanager.googleapis.com --project="${PROJECT_ID}" --quiet
info "cloudresourcemanager.googleapis.com enabled"
gcloud services enable artifactregistry.googleapis.com --project="${PROJECT_ID}" --quiet
info "artifactregistry.googleapis.com enabled"
gcloud services enable compute.googleapis.com --project="${PROJECT_ID}" --quiet
info "compute.googleapis.com enabled"
gcloud services enable run.googleapis.com --project="${PROJECT_ID}" --quiet
info "run.googleapis.com enabled"

# ── 6. provision GCP resources ─────────────────────────────────────────────────

INFRA_DIR="$(dirname "$0")/../infra"
USE_TERRAFORM=false

if command -v terraform &>/dev/null && [[ -f "${INFRA_DIR}/main.tf" ]]; then
  log "Provisioning with Terraform ..."

  # Generate terraform.tfvars from resolved config values.
  cat > "${INFRA_DIR}/terraform.tfvars" <<EOF
project_id      = "${PROJECT_ID}"
region          = "${REGION}"
bq_dataset_id   = "stock_history"
pubsub_topic    = "price-events"
gar_location    = "${REGION}"
gce_zone        = "${REGION}-a"
cloudrun_region = "${REGION}"
EOF
  info "Wrote infra/terraform.tfvars"

  # If the state file is from a different project, clear it so Terraform starts fresh.
  # Without this, switching projects causes Terraform to skip creating resources it thinks
  # already exist (from the old project state), then fail when it can't find them.
  if [[ -f "${INFRA_DIR}/terraform.tfstate" ]]; then
    STATE_PROJECT=$(python3 -c "
import json, sys
try:
    s = json.load(open('${INFRA_DIR}/terraform.tfstate'))
    for r in s.get('resources', []):
        for inst in r.get('instances', []):
            p = inst.get('attributes', {}).get('project', '')
            if p:
                print(p); sys.exit(0)
except: pass
" 2>/dev/null || true)
    if [[ -n "${STATE_PROJECT}" && "${STATE_PROJECT}" != "${PROJECT_ID}" ]]; then
      info "Project changed (${STATE_PROJECT} → ${PROJECT_ID}), clearing Terraform state ..."
      rm -f "${INFRA_DIR}/terraform.tfstate" "${INFRA_DIR}/terraform.tfstate.backup"
    fi
  fi

  terraform -chdir="${INFRA_DIR}" init -input=false -upgrade 2>&1 | sed '/^$/d; s/^/    /'

  # Run apply; on failure, import any pre-existing GCS bucket (common after a partial run)
  # and retry once. All other failures are fatal.
  set +e
  terraform -chdir="${INFRA_DIR}" apply -auto-approve -input=false 2>&1 | sed '/^$/d; s/^/    /'
  TF_EXIT=${PIPESTATUS[0]}
  set -e

  if [[ "${TF_EXIT}" -ne 0 ]]; then
    BUCKET_NAME="${PROJECT_ID}-cdc-resume-tokens"
    if gsutil ls "gs://${BUCKET_NAME}" &>/dev/null 2>&1; then
      info "GCS bucket already exists — importing and retrying ..."
      terraform -chdir="${INFRA_DIR}" import google_storage_bucket.resume_tokens "${BUCKET_NAME}" 2>&1 | sed '/^$/d; s/^/    /' || true
      terraform -chdir="${INFRA_DIR}" apply -auto-approve -input=false 2>&1 | sed '/^$/d; s/^/    /'
    else
      die "Terraform apply failed. Check the errors above, or run 'make infra-destroy' to reset and retry."
    fi
  fi

  # Pull resource names from Terraform outputs instead of hardcoding them.
  GCS_BUCKET=$(terraform -chdir="${INFRA_DIR}" output -raw gcs_bucket_name)
  PUBSUB_TOPIC=$(terraform -chdir="${INFRA_DIR}" output -raw pubsub_topic)
  PUBSUB_SUB=$(terraform -chdir="${INFRA_DIR}" output -raw pubsub_subscription)
  BQ_DATASET=$(terraform -chdir="${INFRA_DIR}" output -raw bq_dataset)

  # Write the SA key to src/ (running inside tools container, so /workspace = src/).
  # The local_file Terraform resource cannot write to the host filesystem correctly
  # when Terraform runs inside a container with different volume mount paths.
  log "Writing service account key ..."
  terraform -chdir="${INFRA_DIR}" output -raw service_account_key_json > service-account-key.json
  chmod 600 service-account-key.json
  info "service-account-key.json written"

  info "Terraform apply complete"
  USE_TERRAFORM=true
else
  log "Terraform not found — falling back to setup_gcp.sh ..."
  bash "$(dirname "$0")/setup_gcp.sh" "${PROJECT_ID}"
  GCS_BUCKET="${PROJECT_ID}-cdc-resume-tokens"
  PUBSUB_TOPIC="price-events"
  PUBSUB_SUB="price-events-sub"
  BQ_DATASET="stock_history"
fi

# ── 7. write .env ──────────────────────────────────────────────────────────────

log "Updating .env ..."
if [[ ! -f ".env" ]]; then
  cp .env.example .env
  info ".env created from .env.example"
fi

# GCP vars — values come from Terraform outputs (or resolved constants for bash path).
set_env_var "GOOGLE_APPLICATION_CREDENTIALS" "./service-account-key.json"
set_env_var "GCP_PROJECT_ID"                 "${PROJECT_ID}"
set_env_var "BQ_DATASET"                     "${BQ_DATASET}"
set_env_var "BQ_TABLE"                       "price_history"
set_env_var "BQ_METADATA_TABLE"              "pipeline_metadata"
set_env_var "PUBSUB_TOPIC"                   "${PUBSUB_TOPIC}"
set_env_var "PUBSUB_SUBSCRIPTION"            "${PUBSUB_SUB}"
set_env_var "GCS_BUCKET"                     "${GCS_BUCKET}"
set_env_var "GCS_RESUME_TOKEN_PATH"          "resume_token.txt"
set_env_var "GAR_LOCATION"                   "${REGION}"
set_env_var "GCE_ZONE"                       "${REGION}-a"
set_env_var "CLOUDRUN_REGION"                "${REGION}"

# MongoDB vars — written only if config.yaml provided real values (not placeholders).
# This avoids overwriting a hand-edited .env on re-runs.
if [[ -n "${YAML_MONGO}" && "${YAML_MONGO}" != "<MONGODB_CONNECTION_STRING>" ]]; then
  set_env_var "MONGO_URI" "${YAML_MONGO}"
fi
if [[ -n "${YAML_DB}" && "${YAML_DB}" != "<DATABASE_NAME>" ]]; then
  set_env_var "DB_NAME" "${YAML_DB}"
fi
if [[ -n "${YAML_COL}" && "${YAML_COL}" != "<COLLECTION_NAME>" ]]; then
  set_env_var "COLLECTION" "${YAML_COL}"
fi
if [[ -n "${YAML_UPDATE_INTERVAL}" ]]; then
  set_env_var "UPDATE_INTERVAL" "${YAML_UPDATE_INTERVAL}"
fi
if [[ -n "${YAML_BURSTY_MODE}" ]]; then
  set_env_var "BURSTY_MODE" "${YAML_BURSTY_MODE}"
fi
if [[ -n "${YAML_BURSTY_MIN}" ]]; then
  set_env_var "BURSTY_MIN" "${YAML_BURSTY_MIN}"
fi
if [[ -n "${YAML_BURSTY_MAX}" ]]; then
  set_env_var "BURSTY_MAX" "${YAML_BURSTY_MAX}"
fi

info ".env updated"

# ── 8. done ────────────────────────────────────────────────────────────────────
# Python dependencies are pre-installed in the tools container image.
# No pip install step needed here.

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  GCP infra provisioned."
echo ""
echo "  Next steps:"
echo "    1. Set MONGO_URI in .env to point at your MongoDB replica set"
echo "    2. make deploy         # build + push subscriber → Cloud Run"
echo "    3. make up             # start local MongoDB"
echo "    4. make listener-up    # start listener container"
echo "    5. make simulate       # generate price updates"
echo ""
echo "  Observe:"
echo "    make validate          # MongoDB == BigQuery?"
echo "    make query ARGS='--name AAPL --latest'"
echo ""
if [[ "${USE_TERRAFORM}" == "true" ]]; then
  echo "  Tear down GCP resources:  make infra-destroy"
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
