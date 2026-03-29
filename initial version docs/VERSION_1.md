# Version 1: End-to-End Pipeline on GCP

## Goal

Connect the Version 0 listener to BigQuery. Captured change events flow from MongoDB to BigQuery via direct streaming inserts. Build a CLI tool that answers point-in-time price queries.

## Prerequisites

- Version 0 working (Docker Compose replica set, simulator, listener catching events).
- A GCP project with billing enabled.
- `gcloud` CLI installed and authenticated.

## What to Build

### 1. GCP Setup Script

A bash script or Terraform config that creates:

- A service account with only these roles:
  - `roles/bigquery.dataEditor` (write to tables)
  - `roles/bigquery.jobUser` (run queries)
- A service account key JSON file downloaded locally (for local development — in production, use workload identity).
- BigQuery dataset: `stock_history`
- BigQuery table: `price_history` with schema:

```sql
name            STRING      NOT NULL
price           FLOAT64     NOT NULL
timestamp       TIMESTAMP   NOT NULL
operation_type  STRING      NOT NULL
event_id        STRING      NOT NULL
ingested_at     TIMESTAMP   NOT NULL
```

- Table partitioned by `DATE(timestamp)`.
- Table clustered by `name`.

### 2. Modify Listener (`listener.py`)

Take the Version 0 listener and add BigQuery writes. For each change stream event:

- Extract `name`, `price`, `clusterTime`, `operationType`, resume token `_id`.
- Convert `clusterTime` (MongoDB Timestamp object) to a Python datetime / ISO string.
- Record `ingested_at` as the current UTC time when the event is processed.
- Construct the `event_id` by serializing the resume token to a string.
- Write the row to BigQuery using the `google-cloud-bigquery` client's `insert_rows_json()` method (streaming insert).
- Log success or failure of each write.

**Important details:**
- `insert_rows_json()` returns a list of errors per row. Check this — an empty list means success, non-empty means partial or full failure. Log any errors.
- Use the service account key JSON via `GOOGLE_APPLICATION_CREDENTIALS` environment variable.
- Set the BigQuery project, dataset, and table as config variables (not hardcoded).

### 3. Query CLI Tool (`query.py`)

A Python script that takes command-line arguments and queries BigQuery.

**Usage:**
```
python query.py --name AAPL --time "2026-03-27 12:05:53"
```

**What it does:**
- Parses `--name` and `--time` arguments.
- Runs the point-in-time query using parameterized SQL:

```sql
SELECT price, timestamp
FROM `{project}.{dataset}.price_history`
WHERE name = @name
  AND timestamp <= @target_time
ORDER BY timestamp DESC
LIMIT 1
```

- Uses `bigquery.QueryJobConfig` with `query_parameters` for safe parameterization (no string interpolation in SQL).
- Prints the result: stock name, price, and the timestamp of that price record.
- If no rows returned, print a message indicating no data exists for that stock at or before the given time.

**Additional query commands to support:**
- `--latest` flag: skip the timestamp filter, just return the most recent price for the given stock.
- `--all-at-time` flag: skip the name filter, return the price of every stock at the given timestamp.

### 4. Verification Test

- Start the MongoDB replica set (`docker-compose up`).
- Run the modified listener (now writing to BigQuery).
- Run the simulator for 30-60 seconds.
- Stop the simulator.
- Run queries and verify:
  - `python query.py --name AAPL --time "<current time>"` returns the latest AAPL price matching what's in MongoDB.
  - `python query.py --name AAPL --time "<30 seconds ago>"` returns an earlier price (different from the latest).
  - `python query.py --name NONEXISTENT --time "<current time>"` prints a "no data found" message.
  - `python query.py --name AAPL --latest` returns the most recent AAPL price.
  - Check the BigQuery table in the GCP console — rows should be appearing with correct timestamps and operation types.
  - Verify that `timestamp` (clusterTime) and `ingested_at` are close but not identical — the delta is the pipeline lag.

## Dependencies (new additions beyond Version 0)

```
google-cloud-bigquery>=3.0
```

## What This Version Does NOT Include

- No Pub/Sub — listener writes directly to BigQuery.
- No resume token persistence — listener starts fresh each time.
- No initial snapshot — only captures changes that happen while the listener is running.
- No deduplication logic.
- No error retry on BigQuery write failures.
- No metadata table.
