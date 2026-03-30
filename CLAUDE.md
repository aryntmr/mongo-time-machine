# CLAUDE.md

## What This Is

MongoDB → Pub/Sub → BigQuery CDC pipeline with point-in-time stock price queries.

---

## Architecture

```
[Your app / simulator.py]  →  MongoDB replica set
                                      │
                          listener.py (Docker container, local machine)
                                      │
                      ├─ no saved token: snapshot → Pub/Sub, then change stream
                      └─ saved token: resume change stream from token
                                      │
                           Pub/Sub (60s ack deadline, 7-day retention, dead letter after 5 fails)
                                      │
                          subscriber.py (Cloud Run, min 1 / max 10 instances)
                                      │
                           BigQuery — price_history (deduped at query time by event_id)

listener.py  →  pipeline_metadata (direct BQ writes)
            →  resume token (GCS, saved every 10s + on shutdown)

query.py  →  price_history (point-in-time, --latest, --all-at-time) + metadata pre-check
validate.py  →  MongoDB vs BigQuery comparison (OK / MISSING / MISMATCH)
```

---

## File Structure

```
infra/
├── main.tf                   # Terraform provider config
├── variables.tf               # input variables (project_id, region, gar_location, gce_zone, cloudrun_region)
├── outputs.tf                 # outputs captured by bootstrap.sh into .env + service_account_key_json
├── bigquery.tf                # BQ dataset + price_history + pipeline_metadata tables
├── pubsub.tf                  # price-events topic + dead-letter topic + subscription
├── storage.tf                 # GCS bucket for resume tokens (versioned, force_destroy)
├── iam.tf                     # service account, 6 IAM roles, SA key resource (key JSON exposed via output)
├── artifact_registry.tf       # GAR repository vali-pipeline (keep last 10 tags)
├── compute.tf                 # GCE vali-listener (optional, production only)
├── cloudrun.tf                # Cloud Run vali-subscriber (min 1 / max 10, placeholder image)
└── terraform.tfvars.example   # template (committed); terraform.tfvars is gitignored

src/
├── config.py               # env vars + get_mongo_client()
├── simulator.py            # random price updates to MongoDB (dev/testing only)
├── listener.py             # snapshot + change stream → Pub/Sub; metadata → BQ; token → GCS
├── subscriber.py           # Pub/Sub → BigQuery micro-batch writer + HTTP health check for Cloud Run
├── query.py                # CLI: --latest, --time, --all-at-time (with dedup CTE + retry)
├── validate.py             # MongoDB vs BigQuery integrity check
├── bootstrap.sh            # one-command setup: reads config.yaml → Terraform → .env → SA key
├── deploy.sh               # build linux/amd64 images → push to GAR → deploy Cloud Run
├── setup_gcp.sh            # fallback provisioning (used when Terraform not installed)
├── Dockerfile.listener     # listener image (python:3.11-slim, non-root)
├── Dockerfile.subscriber   # subscriber image (python:3.11-slim, non-root)
├── Dockerfile.tools        # tools image (gcloud + Terraform + Docker CLI + buildx + Python)
├── .dockerignore           # excludes .env, *.json, __pycache__ from build context
├── config.yaml.example     # user-facing config template (committed); config.yaml is gitignored
├── docker-compose.yml      # 3-node MongoDB replica set + listener + subscriber + tools profiles
├── mongo-init/init.sh      # rs.initiate() + seeds 5 stocks
├── requirements.txt
├── .env.example            # committed template
├── .env                    # never commit
└── Makefile
```

---

## BigQuery Tables

### `price_history`
Partitioned by `DATE(timestamp)`, clustered by `name`.

| Column | Type | Notes |
|--------|------|-------|
| `name` | STRING | Stock ticker |
| `price` | FLOAT64 | Price at event time |
| `timestamp` | TIMESTAMP | MongoDB `clusterTime` — seconds precision |
| `operation_type` | STRING | `snapshot` / `update` / `insert` / `replace` |
| `event_id` | STRING | Resume token, or `snapshot-{pipeline_id}-{_id}` |
| `ingested_at` | TIMESTAMP | Wall clock when subscriber wrote the row |

### `pipeline_metadata`
Append-only. Partitioned by `DATE(started_at)`. Read with `ORDER BY ... DESC LIMIT 1`.

| Column | Type | Notes |
|--------|------|-------|
| `pipeline_id` | STRING | UUID per listener run |
| `started_at` | TIMESTAMP | Process start time |
| `snapshot_completed_at` | TIMESTAMP | Cluster time of baseline snapshot |
| `last_event_timestamp` | TIMESTAMP | Cluster time of last processed event |
| `last_resume_token` | STRING | Resume token of last processed event |
| `status` | STRING | `running` / `stopped` |

---

## Key Things to Know

**`config.get_mongo_client()`** — always use this, never `pymongo.MongoClient` directly. On macOS, `host.docker.internal` may be missing; the function falls back to scanning `localhost:27017/18/19` with `directConnection=true` to find the PRIMARY. This fallback only fires when `MONGO_URI` is the hardcoded default — if `.env` is populated (normal operation), the fallback is never reached.

**PRIMARY is non-deterministic** — any of the 3 nodes can win election. Never assume port 27017 is primary.

**Snapshot gap elimination** — listener pings MongoDB to capture `clusterTime` *before* reading documents, then opens the change stream with `startAtOperationTime` set to that clock. Writes during the scan are caught by the stream. Overlap events (same second) are harmless duplicates — deduped at query time.

**Resume token** — saved to GCS every 10s and on graceful shutdown. On restart: token exists → skip snapshot, resume stream. Token stale (oplog rolled past it) → `OperationFailure` caught → delete token → fresh snapshot.

**Token update ordering** — `state["last_token"] = token` runs unconditionally for every event before the publish block. Prevents a Ctrl+C race where publish succeeds but the token assignment is skipped.

**Pub/Sub ordering not guaranteed** — correctness relies on `ORDER BY timestamp` (MongoDB `clusterTime`), not insertion order.

**Micro-batching** — up to 500 msgs or 2s, whichever first. Ack after successful BQ write; nack on failure → Pub/Sub redelivers. After 5 failures → dead letter topic.

**Deduplication** — duplicates are allowed into `price_history` (Pub/Sub at-least-once + snapshot/stream overlap). All queries in `query.py` use a CTE: `ROW_NUMBER() OVER (PARTITION BY event_id ORDER BY ingested_at ASC) = 1` to collapse them at read time. Write-time dedup is unreliable due to BQ's 30s streaming buffer delay.

**`clusterTime` precision** — `.time` = Unix seconds, `.inc` = ordinal within that second. Only `.time` stored in BQ. Multiple events in the same second share the same timestamp.

**`updatedFields` over `fullDocument`** — for `update` ops, use `updateDescription.updatedFields["price"]`. `fullDocument` comes from `updateLookup` which snapshots the doc *after* the event — a rapid second update can contaminate it.

**`pipeline_metadata` is append-only** — written on: process start, snapshot complete, first event, every 10 events, process exit (`finally` — not on `kill -9`).

**`check_data_coverage`** — warns if query time predates the earliest snapshot. Does not detect mid-run gaps. Returns the snapshot datetime for use in "no data available" messages.

**BQ streaming delay** — up to 30s before streamed rows appear in queries. Wait before querying after stopping the subscriber.

**`GOOGLE_APPLICATION_CREDENTIALS`** — read automatically by BQ and GCS clients. No explicit config needed in Python.

---

## Environment Variables (`src/.env`)

| Variable | Default | Description |
|---|---|---|
| `MONGO_URI` | `mongodb://host.docker.internal:27017,.../?replicaSet=rs0` | Replica set URI |
| `DB_NAME` | `stockdb` | Database |
| `COLLECTION` | `stocks` | Collection |
| `UPDATE_INTERVAL` | `1.0` | Seconds between simulator updates (simulator only) |
| `BURSTY_MODE` | `false` | Random sleep if true (simulator only) |
| `BURSTY_MIN` | `0.1` | Bursty min sleep (s) (simulator only) |
| `BURSTY_MAX` | `3.0` | Bursty max sleep (s) (simulator only) |
| `GOOGLE_APPLICATION_CREDENTIALS` | `./service-account-key.json` | GCP service account key path |
| `GCP_PROJECT_ID` | — | GCP project ID |
| `BQ_DATASET` | `stock_history` | BigQuery dataset |
| `BQ_TABLE` | `price_history` | Price history table |
| `BQ_METADATA_TABLE` | `pipeline_metadata` | Pipeline health table |
| `PUBSUB_TOPIC` | `price-events` | Pub/Sub topic |
| `PUBSUB_SUBSCRIPTION` | `price-events-sub` | Pub/Sub pull subscription |
| `GCS_BUCKET` | — | GCS bucket for resume token |
| `GCS_RESUME_TOKEN_PATH` | `resume_token.txt` | Object path within bucket |
| `GAR_LOCATION` | `us-central1` | Artifact Registry region |
| `GCE_ZONE` | `us-central1-a` | GCE zone (optional GCE listener deployment) |
| `CLOUDRUN_REGION` | `us-central1` | Cloud Run region |

---

## How to Run

```bash
cd src

# First-time setup (Docker Desktop is the only prerequisite)
cp config.yaml.example config.yaml   # fill in gcp.project_id + mongodb fields
make bootstrap                        # provisions GCP infra + writes .env + SA key
make deploy                           # builds AMD64 subscriber image → GAR → Cloud Run

# Start local MongoDB (skip if using your own MongoDB)
make up

# Start listener
make listener-up

# Optional: run simulator against local MongoDB
make simulate

# Query (wait ~30s after starting pipeline for BQ streaming buffer)
make query ARGS='--name AAPL --latest'
make query ARGS='--name AAPL --time "2026-03-29 12:00:00"'
make query ARGS='--all-at-time "2026-03-29 12:00:00"'

# Validate
make validate   # exit 0 = OK, exit 1 = MISSING or MISMATCH

# Tear down
make listener-down
make down                # stop MongoDB, remove volumes
make infra-destroy       # removes all GCP resources via Terraform
```

---

## Infrastructure (Terraform)

All GCP resources are defined in `infra/` and provisioned by `bootstrap.sh`. All tooling runs inside the tools container — Docker Desktop is the only host prerequisite.

**Resources created:**
- BigQuery dataset `stock_history` + tables `price_history` and `pipeline_metadata`
- Pub/Sub topic `price-events` + dead-letter topic + subscription `price-events-sub`
- GCS bucket `{project_id}-cdc-resume-tokens` (versioned, force_destroy enabled)
- Artifact Registry repository `vali-pipeline` (keep last 10 image tags)
- Cloud Run service `vali-subscriber` (min 1 / max 10 instances, placeholder image on first apply)
- GCE instance `vali-listener` (optional, production only — listener runs locally by default)
- Service account `vali-pipeline` with roles: `bigquery.dataEditor`, `bigquery.jobUser`, `pubsub.publisher`, `pubsub.subscriber`, `storage.objectAdmin`, `artifactregistry.reader`
- SA key extracted from Terraform output and written to `src/service-account-key.json` by `bootstrap.sh`

**bootstrap.sh behaviour:**
- Reads `config.yaml` → writes `infra/terraform.tfvars` + `src/.env`
- Detects if active gcloud account can't access the project → re-authenticates inline
- Detects project change in Terraform state and clears it automatically
- Imports pre-existing GCS bucket on re-runs to avoid 409 conflicts
- Extracts SA key via `terraform output -raw service_account_key_json` → writes `service-account-key.json`
- Falls back to `setup_gcp.sh` if Terraform is not installed

**deploy.sh behaviour:**
- Default: subscriber to Cloud Run only (listener runs locally)
- `--listener-only`: listener to GCE only
- `--all`: both
- Builds images with `docker buildx build --platform linux/amd64` (cross-compiles AMD64 on M1/M2 Macs)

**Makefile targets:** `bootstrap`, `deploy`, `deploy-subscriber`, `deploy-listener`, `up`, `down`, `listener-up`, `listener-down`, `pipeline-up`, `pipeline-down`, `simulate`, `validate`, `query`, `infra-init`, `infra-plan`, `infra-apply`, `infra-destroy`
