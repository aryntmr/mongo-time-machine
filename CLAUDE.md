# CLAUDE.md

## What This Is

MongoDB → Pub/Sub → BigQuery CDC pipeline with point-in-time stock price queries.

---

## Architecture

```
simulator.py  →  MongoDB replica set (Docker)
                      │
                      ├─ no saved token: snapshot → Pub/Sub, then change stream
                      └─ saved token: resume change stream from token
                                │
                           Pub/Sub (60s ack deadline, 7-day retention, dead letter after 5 fails)
                                │
                          subscriber.py (micro-batch: 500 msgs or 2s → insert_rows_json)
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
src/
├── config.py          # env vars + get_mongo_client()
├── simulator.py       # random price updates to MongoDB
├── listener.py        # snapshot + change stream → Pub/Sub; metadata → BQ; token → GCS
├── subscriber.py      # Pub/Sub → BigQuery micro-batch writer
├── query.py           # CLI: --latest, --time, --all-at-time (with dedup CTE + retry)
├── validate.py        # MongoDB vs BigQuery integrity check
├── bootstrap.sh       # one-command GCP + Python setup
├── setup_gcp.sh       # provisions IAM, BQ, Pub/Sub, GCS
├── docker-compose.yml # 3-node MongoDB replica set
├── mongo-init/init.sh # rs.initiate() + seeds 5 stocks
├── requirements.txt
├── .env.example       # committed template
├── .env               # never commit
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

**`config.get_mongo_client()`** — always use this, never `pymongo.MongoClient` directly. On macOS, `host.docker.internal` may be missing; the function falls back to scanning `localhost:27017/18/19` with `directConnection=true` to find the PRIMARY.

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
| `UPDATE_INTERVAL` | `1.0` | Seconds between simulator updates |
| `BURSTY_MODE` | `false` | Random sleep if true |
| `BURSTY_MIN` | `0.1` | Bursty min sleep (s) |
| `BURSTY_MAX` | `3.0` | Bursty max sleep (s) |
| `GOOGLE_APPLICATION_CREDENTIALS` | `./service-account-key.json` | GCP service account key path |
| `GCP_PROJECT_ID` | — | GCP project ID |
| `BQ_DATASET` | `stock_history` | BigQuery dataset |
| `BQ_TABLE` | `price_history` | Price history table |
| `BQ_METADATA_TABLE` | `pipeline_metadata` | Pipeline health table |
| `PUBSUB_TOPIC` | `price-events` | Pub/Sub topic |
| `PUBSUB_SUBSCRIPTION` | `price-events-sub` | Pub/Sub pull subscription |
| `GCS_BUCKET` | — | GCS bucket for resume token |
| `GCS_RESUME_TOKEN_PATH` | `resume_token.txt` | Object path within bucket |

---

## How to Run

```bash
cd src

# First-time setup
python3 -m venv .venv && source .venv/bin/activate
gcloud auth login
bash bootstrap.sh <gcp-project-id>

# Start MongoDB replica set
docker compose up -d
docker compose logs mongo-setup   # wait for: PRIMARY elected + Seeded 5 stocks

# Terminal 1 — subscriber (start before listener)
source .venv/bin/activate && python subscriber.py

# Terminal 2 — listener
source .venv/bin/activate && python listener.py

# Terminal 3 — simulator
source .venv/bin/activate && python simulator.py

# Query (wait ~30s after stopping subscriber for BQ streaming delay)
python query.py --name AAPL --latest
python query.py --name AAPL --time "2026-03-29 12:00:00"
python query.py --all-at-time "2026-03-29 12:00:00"

# Validate
python validate.py   # exit 0 = OK, exit 1 = MISSING or MISMATCH

# Tear down
docker compose down -v
```
