# Project Reference: MongoDB Time Travel Pipeline

## Project Summary

A CDC (Change Data Capture) pipeline that watches a MongoDB collection for price changes, stores every change with its exact timestamp in BigQuery on GCP, and exposes a query interface to retrieve the exact price of any stock at any point in time.

## Architecture

```
MongoDB (source) 
    │
    │ Change Stream (persistent connection, real-time events)
    ▼
Listener Service (Python, runs on Compute Engine)
    │
    │ Publishes JSON events
    ▼
Google Cloud Pub/Sub (topic + pull subscription + dead letter topic)
    │
    │ Pulls in micro-batches
    ▼
Subscriber Worker (Python, runs on Cloud Run)
    │
    │ Streaming inserts
    ▼
BigQuery (historical store, partitioned by date, clustered by name)
    │
    │ Point-in-time SQL query
    ▼
Query Interface (Python CLI + optional Cloud Run REST API)
```

## Components

### 1. Mock Simulator
- Python script that runs locally.
- Connects to local MongoDB replica set.
- Randomly updates stock prices at configurable frequency.
- Used only for development and testing — not part of the production pipeline.

### 2. Listener Service
- Python service using `pymongo` change stream API.
- Connects to MongoDB replica set with `fullDocument: "updateLookup"` to get full document on every update.
- On first startup: reads the entire MongoDB collection as a baseline snapshot, writes all documents to Pub/Sub with `operation_type: "snapshot"`.
- After snapshot: opens a change stream using `startAtOperationTime` matching the snapshot time.
- Publishes each change event to Pub/Sub as a JSON message.
- Persists the change stream resume token to a GCS file every 10 seconds.
- On restart: reads resume token from GCS, resumes change stream from that point.
- Updates a metadata record in BigQuery periodically with pipeline health info.
- Runs on Compute Engine (needs persistent TCP connection to MongoDB).

### 3. Pub/Sub
- One topic for price change events.
- One pull subscription for the subscriber worker.
- One dead letter topic — messages that fail delivery 5 times are routed here.
- Message retention: 7 days.
- Acknowledgment deadline: 60 seconds.

### 4. Subscriber Worker
- Python service using `google-cloud-pubsub` subscriber client.
- Pulls messages from Pub/Sub subscription.
- Micro-batches: collects events for up to 2 seconds or 500 events (whichever first), then writes to BigQuery in one streaming insert call.
- Handles deduplication using `event_id`.
- Retries failed BigQuery writes with exponential backoff.
- Runs on Cloud Run.

### 5. BigQuery

**Main table: `price_history`**

| Column | Type | Description |
|--------|------|-------------|
| name | STRING | Stock/company name |
| price | FLOAT64 | Price at time of change |
| timestamp | TIMESTAMP | MongoDB clusterTime — when the write was committed |
| operation_type | STRING | insert / update / replace / snapshot |
| event_id | STRING | Change stream resume token (deduplication key) |
| ingested_at | TIMESTAMP | When the pipeline processed the event |

- Partitioned by `DATE(timestamp)`
- Clustered by `name`

**Metadata table: `pipeline_metadata`**

| Column | Type | Description |
|--------|------|-------------|
| pipeline_id | STRING | Unique ID per deployment |
| started_at | TIMESTAMP | When the listener started |
| snapshot_completed_at | TIMESTAMP | When the initial snapshot finished |
| last_event_timestamp | TIMESTAMP | Most recent event timestamp processed |
| last_resume_token | STRING | Latest persisted resume token |
| status | STRING | running / stopped / gap_detected |

### 6. Query Interface

**CLI tool:** `python query.py --name AAPL --time "2026-03-27 12:05:53"`

**Core SQL:**
```sql
SELECT price, timestamp
FROM `project.dataset.price_history`
WHERE name = @name
  AND timestamp <= @target_time
ORDER BY timestamp DESC
LIMIT 1
```

Returns the most recent price at or before the requested timestamp.

**Additional query patterns:**
- Range query: all prices of a stock between two timestamps.
- Diff query: price change between two timestamps.
- Latest price: most recent recorded price of a stock.
- Snapshot query: all stock prices at a given timestamp.

**Optional Cloud Run API:** REST endpoint wrapping the same query logic. `GET /price?name=AAPL&time=2026-03-27T12:05:53Z`

### 7. GCS Bucket
- Stores the listener's resume token file.
- Updated every 10 seconds by the listener.
- Read on listener startup to resume from last position.

### 8. Infrastructure Setup
- Terraform config or `gcloud` CLI bash script that creates all GCP resources: BigQuery dataset + tables, Pub/Sub topic + subscriptions, GCS bucket, service account with least-privilege IAM roles, Compute Engine instance for listener.
- `config.yaml` template for user to fill in: MongoDB connection string, GCP project ID, database and collection names.

## Tech Stack

| Component | Technology |
|-----------|-----------|
| Language | Python 3.9+ |
| Source DB | MongoDB 3.6+ (replica set required) |
| CDC mechanism | MongoDB Change Streams |
| Message queue | Google Cloud Pub/Sub |
| Historical store | Google BigQuery |
| Resume token storage | Google Cloud Storage |
| Listener host | Google Compute Engine |
| Subscriber host | Google Cloud Run |
| Query interface | Python CLI + optional Cloud Run API |
| Infrastructure as code | Terraform or gcloud CLI script |
| Local dev | Docker Compose (3-node MongoDB replica set) |
| Containerization | Docker |


