# CLAUDE.md

## What This Is

A CDC pipeline. `simulator.py` writes random stock price updates to a MongoDB replica set. `listener.py` opens a change stream, captures every update in real time, and writes each event to BigQuery. `query.py` answers point-in-time price queries against BigQuery.

---

## Architecture

```
simulator.py
    │
    │  update_one()
    ▼
MongoDB 3-node replica set (Docker)
    │
    │  change stream (event-driven, persistent)
    ▼
listener.py
    │
    │  insert_rows_json() — one row per event
    ▼
BigQuery (price_history table)
    │
    │  parameterized SQL
    ▼
query.py
```

---

## File Structure

```
src/
├── config.py              # all config vars + get_mongo_client()
├── simulator.py           # writes random price updates to MongoDB in a loop
├── listener.py            # change stream → BigQuery streaming insert per event
├── query.py               # CLI: point-in-time, --latest, --all-at-time queries
├── bootstrap.sh           # one-command GCP + Python setup (run once)
├── setup_gcp.sh           # provisions service account, IAM, BQ dataset + table
├── docker-compose.yml     # 3-node MongoDB replica set (mongo1/2/3)
├── mongo-init/
│   └── init.sh            # rs.initiate() + seeds 5 stocks, runs once on first up
├── requirements.txt       # pymongo, python-dotenv, google-cloud-bigquery
├── .env.example           # config template — committed
├── .env                   # real values — never commit
└── Makefile               # shortcuts: make up/down/listen/simulate/query/bootstrap
```

---

## Key Things to Know

**Always use `config.get_mongo_client()`** — never instantiate `pymongo.MongoClient` directly. On macOS, `host.docker.internal` is often absent from `/etc/hosts`, so the function does a DNS check first and falls back to scanning `localhost:27017/18/19` with `directConnection=true` to find the current PRIMARY.

**PRIMARY is non-deterministic** — any of the 3 nodes can win the election. Never assume port 27017 is the primary.

**`clusterTime` is seconds + ordinal** — `.time` is Unix seconds, `.inc` is an ordering counter within that second, not a fractional second.

**`fullDocument.price` can have a race condition** — `updateLookup` snapshots the document after the event fires, so a rapid second update can contaminate it. The atomic source is `updateDescription.updatedFields["price"]` for update operations. The listener uses this for `update` events and falls back to `fullDocument["price"]` for insert/replace.

**BigQuery streaming insert delay** — rows written via `insert_rows_json()` may take up to 30 seconds before they appear in query results.

**`GOOGLE_APPLICATION_CREDENTIALS`** is read automatically by the BigQuery client from the environment — no explicit config needed in Python.

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

# 3. terminal 1 — listener (writes to BigQuery)
source .venv/bin/activate && python listener.py

# 4. terminal 2 — simulator
source .venv/bin/activate && python simulator.py

# 5. query BigQuery
python query.py --name AAPL --latest
python query.py --name AAPL --time "2026-03-29 12:00:00"
python query.py --all-at-time "2026-03-29 12:00:00"

# tear down
docker compose down -v
```
