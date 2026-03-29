# Version 1: End-to-End Pipeline on GCP

## Goal

Connect the change stream listener to BigQuery. Every MongoDB change event flows into BigQuery as an append-only row. A CLI tool answers point-in-time price queries.

## What Was Built

### 1. GCP Setup (`setup_gcp.sh` + `bootstrap.sh`)

`bootstrap.sh` is the single entry point — run once on any machine:
- Checks gcloud is installed and authenticated (opens browser login if not)
- Enables BigQuery API on the project
- Calls `setup_gcp.sh` which creates: service account `vali-pipeline` with `roles/bigquery.dataEditor` and `roles/bigquery.jobUser`, downloads `service-account-key.json`, creates BigQuery dataset `stock_history` and table `price_history`
- Writes GCP vars into `.env` without touching existing Mongo vars
- Runs `python3 -m pip install -r requirements.txt`

BigQuery table schema:

| Column | Type | Description |
|--------|------|-------------|
| `name` | STRING | Stock identifier |
| `price` | FLOAT64 | Price at time of change |
| `timestamp` | TIMESTAMP | MongoDB `clusterTime` — when the write committed |
| `operation_type` | STRING | insert / update / replace |
| `event_id` | STRING | Resume token `_id._data` — unique per event |
| `ingested_at` | TIMESTAMP | When the listener processed the event |

Table is partitioned by `DATE(timestamp)`, clustered by `name`.

### 2. `config.py`

Three new vars added:

| Variable | Default |
|---|---|
| `GCP_PROJECT_ID` | — |
| `BQ_DATASET` | `stock_history` |
| `BQ_TABLE` | `price_history` |

`GOOGLE_APPLICATION_CREDENTIALS` is read automatically by the BigQuery client from the environment.

### 3. `listener.py`

`bigquery.Client` is initialised once at startup (not per event). For each change stream event:

- **Price extraction:** uses `updateDescription.updatedFields["price"]` for `update` operations (atomic, avoids `fullDocument` race condition). Falls back to `fullDocument["price"]` for insert/replace.
- **Timestamp:** `datetime.fromtimestamp(clusterTime.time, tz=timezone.utc)` — seconds-precision UTC.
- **`event_id`:** `event["_id"]["_data"]` — the resume token string.
- **`ingested_at`:** `datetime.now(tz=timezone.utc)` at processing time.
- Calls `bq_client.insert_rows_json(table_ref, [row])`. Returns a list — empty means success, non-empty means error. Both cases are logged.

### 4. `query.py`

CLI tool. Three modes, all using `bigquery.QueryJobConfig` with `query_parameters` — no string interpolation in SQL.

**Point-in-time** (`--name AAPL --time "2026-03-29 12:00:00"`):
```sql
SELECT price, timestamp FROM price_history
WHERE name = @name AND timestamp <= @target_time
ORDER BY timestamp DESC LIMIT 1
```

**Latest** (`--name AAPL --latest`): same query without the time filter.

**Snapshot** (`--all-at-time "2026-03-29 12:00:00"`):
```sql
SELECT name, price, timestamp FROM price_history
WHERE timestamp <= @target_time
QUALIFY ROW_NUMBER() OVER (PARTITION BY name ORDER BY timestamp DESC) = 1
ORDER BY name
```

Prints a clean result line or "No data found" message. `--time` and `--all-at-time` are registered as `type=parse_time` in argparse so bad input produces a clean error, not a traceback.

## Dependencies

```
pymongo>=4.0
python-dotenv>=1.0
google-cloud-bigquery>=3.0
```

## Verification

```bash
docker compose up -d
# wait for: PRIMARY elected + Seeded 5 stocks

python listener.py   # terminal 1
python simulator.py  # terminal 2 — run for ~30 seconds, then Ctrl+C
```

Verified:
- Every event appears in listener with `[BQ OK]`
- `--latest` returns the most recent price
- `--time` at two different points returns two different prices
- `--name NONEXISTENT` returns "No data found"
- `--all-at-time` returns all 5 stocks at their correct prices for that moment
- `timestamp` (clusterTime) and `ingested_at` are close but not identical — the delta is pipeline lag

## What This Version Does Not Include

- No Pub/Sub — listener writes directly to BigQuery
- No resume token persistence — listener starts fresh on restart
- No initial snapshot — only captures changes while listener is running
- No deduplication
- No BigQuery write retry
- No metadata table
