# Vali Health CDC Pipeline

MongoDB → Pub/Sub → BigQuery change-data-capture pipeline with point-in-time stock price queries. Captures every price update via MongoDB change streams, fans out through Pub/Sub, and lands in BigQuery for millisecond-precision historical queries.

---

## Architecture

```
simulator.py  →  MongoDB replica set (Docker)
                      │
                      ├─ no saved token: full snapshot → Pub/Sub, then change stream
                      └─ saved token: resume change stream from token
                                │
                           Pub/Sub (60s ack deadline · 7-day retention · dead letter after 5 fails)
                                │
                          subscriber.py  (micro-batch: 500 msgs or 2s → insert_rows_json)
                                │
                           BigQuery — price_history  (deduped at query time by event_id)

listener.py  →  pipeline_metadata (direct BQ writes)
            →  resume token (GCS, saved every 10s + on shutdown)
```

---

## Prerequisites

- [gcloud CLI](https://cloud.google.com/sdk/docs/install)
- [Terraform](https://developer.hashicorp.com/terraform/install) >= 1.0
- [Docker + Docker Compose](https://docs.docker.com/get-docker/)
- Python 3.9+
- A GCP project with **billing enabled**

---

## Quick Start

**1. Authenticate**
```bash
gcloud auth login
gcloud auth application-default login
```

**2. Configure**
```bash
cd src
cp config.yaml.example config.yaml
# Edit config.yaml — fill in gcp.project_id and mongodb fields
```

**3. Bootstrap** (provisions all GCP resources + populates `.env`)
```bash
python3 -m venv .venv && source .venv/bin/activate
bash bootstrap.sh
```

**4. Start MongoDB**
```bash
make up
docker compose logs mongo-setup   # wait for: PRIMARY elected + Seeded 5 stocks
```

**5. Run the pipeline** (three separate terminals, all in `src/` with venv active)
```bash
make subscribe   # terminal 1 — Pub/Sub → BigQuery
make listen      # terminal 2 — MongoDB CDC → Pub/Sub
make simulate    # terminal 3 — price updates
```

---

## Querying

Wait ~30s after starting the pipeline for BigQuery's streaming buffer to settle.

```bash
# Latest price for a stock
python query.py --name AAPL --latest

# Price at a specific point in time
python query.py --name AAPL --time "2026-03-29 12:00:00"

# All stock prices at a point in time
python query.py --all-at-time "2026-03-29 12:00:00"
```

---

## Validation

Compares every document in MongoDB against BigQuery row-by-row.

```bash
python validate.py   # exit 0 = OK · exit 1 = MISSING or MISMATCH
```

Wait ~30s after stopping the subscriber before running, to allow BigQuery's streaming buffer to flush.

---

## Tear Down

```bash
docker compose down -v   # stop MongoDB, remove volumes
make infra-destroy       # destroy all GCP resources via Terraform
```

---

## Troubleshooting

**`PRIMARY not found` on startup**
MongoDB replica set election takes 10–20s. Wait and retry, or check logs: `docker compose logs mongo-setup`.

**`config.yaml` values not applied**
You must activate the venv before running bootstrap: `source .venv/bin/activate`. Without it, pyyaml may not be installed and values silently fall back to prompts.

**`terraform apply` fails with "already exists"**
A previous partial run left resources in GCP. Re-running `bash bootstrap.sh` handles this automatically — it imports the existing resource and retries.

**Switching to a new GCP project**
bootstrap.sh detects the project change, clears the stale Terraform state, and provisions fresh. Just update `gcp.project_id` in `config.yaml` and re-run.

**`validate.py` reports MISSING rows**
BigQuery streaming inserts have up to 30s delay. Stop the subscriber, wait 30s, then run `validate.py`.

**Resume token stale (`OperationFailure` in listener)**
The MongoDB oplog rolled past the saved token. The listener handles this automatically: deletes the token and performs a fresh snapshot.

**`gcloud: No ADC found`**
Run `gcloud auth application-default login` and retry bootstrap.

**`No billing account`**
Terraform cannot enable GCP APIs without billing. Enable billing on the project at console.cloud.google.com before running bootstrap.
