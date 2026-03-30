# CLAUDE.md

## What This Is

A CDC pipeline. `simulator.py` writes random stock price updates to a MongoDB replica set. `listener.py` takes a baseline snapshot of MongoDB on startup (or resumes from a saved token), then opens a change stream and publishes every event to Google Cloud Pub/Sub. `subscriber.py` pulls events from Pub/Sub in micro-batches and writes them to BigQuery. `query.py` answers point-in-time price queries against BigQuery. `validate.py` verifies the pipeline hasn't missed any events by comparing current MongoDB state against BigQuery history.

---

## Architecture

```
simulator.py
    │
    │  update_one()
    ▼
MongoDB 3-node replica set (Docker)
    │
    ├─── on startup (no saved token): full collection read → Pub/Sub (snapshot events)
    │    on startup (saved token): resume change stream from token (no snapshot)
    │
    └─── persistent change stream
              │
              │  publisher.publish() — one message per event
              ▼
         Google Cloud Pub/Sub — price-events topic
              │
              │  pull subscription (ack deadline 60s, 7-day retention)
              │  dead letter topic after 5 failed deliveries
              ▼
         subscriber.py — micro-batch writer
              │
              │  insert_rows_json() — up to 500 rows or 2 seconds
              ▼
         BigQuery — price_history

listener.py
    ├── metadata rows ──→ BigQuery — pipeline_metadata (direct writes, unchanged)
    └── resume token ──→ GCS bucket (saved every 10s, loaded on startup)

BigQuery — price_history
    │
    │  parameterized SQL (point-in-time, latest, all-at-time)
    ▼
query.py  ←──  pre-check against pipeline_metadata (warn if query predates first snapshot)

validate.py
    ├── reads current prices from MongoDB
    ├── reads latest prices from BigQuery
    └── compares: OK / MISSING / MISMATCH per stock
```

---

## File Structure

```
src/
├── config.py              # all config vars + get_mongo_client()
├── simulator.py           # writes random price updates to MongoDB in a loop
├── listener.py            # snapshot + change stream → Pub/Sub; writes pipeline_metadata; saves resume token to GCS
├── subscriber.py          # pulls from Pub/Sub, micro-batches into BigQuery price_history
├── query.py               # CLI: point-in-time, --latest, --all-at-time queries (+ metadata pre-check)
├── validate.py            # compares current MongoDB state vs BigQuery history (OK/MISSING/MISMATCH)
├── bootstrap.sh           # one-command GCP + Python setup (run once)
├── setup_gcp.sh           # provisions service account, IAM, BQ dataset + tables, Pub/Sub, GCS bucket
├── docker-compose.yml     # 3-node MongoDB replica set (mongo1/2/3)
├── mongo-init/
│   └── init.sh            # rs.initiate() + seeds 5 stocks, runs once on first up
├── requirements.txt       # pymongo, python-dotenv, google-cloud-bigquery, google-cloud-pubsub, google-cloud-storage
├── .env.example           # config template — committed
├── .env                   # real values — never commit
└── Makefile               # shortcuts: make up/down/listen/subscribe/simulate/query/validate/bootstrap
```

---

## BigQuery Tables

### `price_history`
Every price event ever recorded. Partitioned by `DATE(timestamp)`, clustered by `name`.

| Column | Type | Description |
|--------|------|-------------|
| `name` | STRING | Stock name |
| `price` | FLOAT64 | Price at time of change |
| `timestamp` | TIMESTAMP | MongoDB `clusterTime` — seconds precision, UTC |
| `operation_type` | STRING | `snapshot` / `update` / `insert` / `replace` |
| `event_id` | STRING | Resume token (change events) or `snapshot-{pipeline_id}-{_id}` (snapshots) |
| `ingested_at` | TIMESTAMP | When the pipeline wrote this row |

### `pipeline_metadata`
One row appended per lifecycle event. Partitioned by `DATE(started_at)`.

| Column | Type | Description |
|--------|------|-------------|
| `pipeline_id` | STRING | UUID generated fresh on each `listener.py` start |
| `started_at` | TIMESTAMP | When this listener process started |
| `snapshot_completed_at` | TIMESTAMP | Cluster time of the baseline snapshot |
| `last_event_timestamp` | TIMESTAMP | Cluster time of the most recently processed event |
| `last_resume_token` | STRING | Resume token of the most recently processed event |
| `status` | STRING | `running` / `stopped` |

---

## Key Things to Know

**Always use `config.get_mongo_client()`** — never instantiate `pymongo.MongoClient` directly. On macOS, `host.docker.internal` is often absent from `/etc/hosts`, so the function does a DNS check first and falls back to scanning `localhost:27017/18/19` with `directConnection=true` to find the current PRIMARY.

**PRIMARY is non-deterministic** — any of the 3 nodes can win the election. Never assume port 27017 is the primary.

**Snapshot before change stream** — on first startup (no saved resume token), `listener.py` pings MongoDB to capture the current cluster time, reads all documents, and publishes them to Pub/Sub with `operation_type="snapshot"`. The change stream then opens with `startAtOperationTime` set to that cluster time. This eliminates the gap between the snapshot read and the first change event. Events that overlap (same second as the snapshot) appear as harmless duplicates — V4 deduplication resolves them.

**Resume token persistence** — the listener saves the latest change stream resume token to a GCS file every 10 seconds. On restart, if a saved token exists, the listener skips the snapshot and resumes the change stream from that token. If the token is stale (MongoDB oplog rolled past it), the listener falls back to a fresh snapshot. The token is also saved on graceful shutdown (Ctrl+C / `finally` block).

**Pub/Sub does not guarantee ordering** — this doesn't affect correctness because BigQuery queries use `ORDER BY timestamp` (MongoDB `clusterTime`) for ordering, not insertion order. The subscriber writes rows in whatever order they arrive; the query layer handles sequencing.

**Subscriber micro-batching** — `subscriber.py` collects up to 500 messages or waits 2 seconds (whichever comes first), then writes the batch to BigQuery in one `insert_rows_json` call. Messages are acked only after a successful write; nacked on failure so Pub/Sub redelivers them. After 5 failed deliveries, messages go to the dead letter topic.

**`clusterTime` is seconds + ordinal** — `.time` is Unix seconds, `.inc` is an ordering counter within that second, not a fractional second. Only `.time` is stored in BigQuery's `timestamp` column. Two events within the same second share the same timestamp value.

**`fullDocument.price` can have a race condition** — `updateLookup` snapshots the document after the event fires, so a rapid second update can contaminate it. The atomic source is `updateDescription.updatedFields["price"]` for update operations. The listener uses this for `update` events and falls back to `fullDocument["price"]` for insert/replace.

**`pipeline_metadata` is append-only** — BigQuery streaming inserts cannot update rows. Each status change is a new row. To read current state, always query with `ORDER BY ... DESC LIMIT 1`. Metadata is written directly by the listener (not through Pub/Sub) on: process start, snapshot completion, first event, every 10 events, and process exit (via `finally` — fires on both clean shutdown and crashes, but not on `kill -9`).

**`check_data_coverage` uses the earliest snapshot** — `query.py` warns if a requested timestamp is before the very first snapshot ever recorded across all pipeline runs. It does NOT detect gaps between runs (e.g., pipeline was down for 5 minutes).

**BigQuery streaming insert delay** — rows written via `insert_rows_json()` may take up to 30 seconds before they appear in query results. Wait before querying after stopping the subscriber.

**`GOOGLE_APPLICATION_CREDENTIALS`** is read automatically by the BigQuery and GCS clients from the environment — no explicit config needed in Python.

---

## Environment Variables (`src/.env`)

| Variable | Default | Description |
|---|---|---|
| `MONGO_URI` | `mongodb://host.docker.internal:27017,.../?replicaSet=rs0` | Replica set URI |
| `DB_NAME` | `stockdb` | Database |
| `COLLECTION` | `stocks` | Collection |
| `UPDATE_INTERVAL` | `1.0` | Seconds between simulator updates |
| `BURSTY_MODE` | `false` | Random sleep if true |
| `BURSTY_MIN` | `0.1` | Bursty mode min sleep (seconds) |
| `BURSTY_MAX` | `3.0` | Bursty mode max sleep (seconds) |
| `GOOGLE_APPLICATION_CREDENTIALS` | `./service-account-key.json` | Path to GCP service account key |
| `GCP_PROJECT_ID` | — | GCP project ID |
| `BQ_DATASET` | `stock_history` | BigQuery dataset |
| `BQ_TABLE` | `price_history` | BigQuery table |
| `BQ_METADATA_TABLE` | `pipeline_metadata` | BigQuery pipeline health table |
| `PUBSUB_TOPIC` | `price-events` | Pub/Sub topic for price events |
| `PUBSUB_SUBSCRIPTION` | `price-events-sub` | Pub/Sub pull subscription |
| `GCS_BUCKET` | — | GCS bucket for resume token storage |
| `GCS_RESUME_TOKEN_PATH` | `resume_token.txt` | Object path within the GCS bucket |

---

## How to Run

```bash
cd src

# 1. first-time setup (GCP + venv + deps)
python3 -m venv .venv
source .venv/bin/activate
gcloud auth login
bash bootstrap.sh <gcp-project-id>

# 2. start the replica set
docker compose up -d
docker compose logs mongo-setup   # wait for: PRIMARY elected + Seeded 5 stocks

# 3. terminal 1 — subscriber (Pub/Sub → BigQuery)
source .venv/bin/activate && python subscriber.py

# 4. terminal 2 — listener (MongoDB → Pub/Sub)
#    first run: takes baseline snapshot, publishes to Pub/Sub
#    subsequent runs: resumes from saved token (no snapshot)
source .venv/bin/activate && python listener.py

# 5. terminal 3 — simulator
source .venv/bin/activate && python simulator.py

# 6. wait ~30 seconds after stopping subscriber before querying
#    (BigQuery streaming insert delay)

# 7. query BigQuery
python query.py --name AAPL --latest
python query.py --name AAPL --time "2026-03-29 12:00:00"
python query.py --all-at-time "2026-03-29 12:00:00"

# 8. validate pipeline integrity (run after subscriber has been up and data has settled)
python validate.py   # exit 0 = all OK, exit 1 = MISSING or MISMATCH detected

# tear down
docker compose down -v
```
