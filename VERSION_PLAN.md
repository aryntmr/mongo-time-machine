# Version Plan: V0 — V7

---

## Version 0 — Local Proof of Concept

**Goal:** Prove the core CDC loop works locally.

**What gets built:**
- Docker Compose with 3-node MongoDB replica set (not standalone).
- Mock simulator with configurable update frequency and random walk price movements.
- Change stream listener that connects, receives events, and logs them with full metadata — cluster timestamp, operation type, full document, resume token.
- Verification that: every update from simulator appears in listener, clusterTime is sub-second precision, order matches, multiple rapid updates to same stock all appear as separate events.
- Listener uses `fullDocument: "updateLookup"` to get the complete document on every update (not just changed fields).

---

## Version 1 — End-to-End Pipeline on GCP

**Goal:** Connect the listener to BigQuery. First working end-to-end pipeline.

**What gets built:**
- GCP project setup: service account with least-privilege roles (`bigquery.dataEditor`, `bigquery.jobUser` only).
- BigQuery dataset and table with schema: `name STRING, price FLOAT64, timestamp TIMESTAMP, operation_type STRING, event_id STRING, ingested_at TIMESTAMP`. Partitioned by `DATE(timestamp)`, clustered by `name`.
- Listener modified to write each event to BigQuery via streaming inserts (`insert_rows_json`).
- `ingested_at` recorded separately from `timestamp` — the delta between them is pipeline lag.
- `event_id` derived from the change stream resume token — serves as natural deduplication key for later versions.
- Python CLI query tool: takes `--name` and `--time`, runs parameterized point-in-time SQL, returns the exact price.
- Additional query patterns: `--latest` (most recent price), `--all-at-time` (all stocks at a given timestamp).
- Error logging on BigQuery write failures (no retry yet).

---

## Version 2 — Data Integrity Layer

**Goal:** Handle the "history before deployment" problem and guarantee data completeness.

**What gets built:**
- On startup, before opening the change stream, the listener reads the entire MongoDB collection and writes every document to BigQuery with `operation_type: "snapshot"`. This is the baseline.
- Change stream opened using `startAtOperationTime` aligned to the snapshot timestamp — no gap between snapshot and first change event. May produce duplicates (handled by deduplication in Version 4).
- Metadata table in BigQuery (`pipeline_metadata`): `pipeline_id, started_at, snapshot_completed_at, last_event_timestamp, last_resume_token, status`. Listener updates this periodically.
- Query tool checks the metadata table before returning results — if the requested timestamp falls before the snapshot or in a known gap, it warns instead of silently returning stale data.
- Data validation script: compares current MongoDB state against the latest state implied by BigQuery event history. For each stock, replays events and checks that the final price matches what's currently in MongoDB. Detects missed events.

---

## Version 3 — Durability with Pub/Sub

**Goal:** Decouple ingestion from storage so events are never lost if BigQuery is slow or the writer crashes.

**What gets built:**
- Pub/Sub topic for price change events.
- Pull subscription with 60-second acknowledgment deadline.
- Dead letter topic — messages that fail delivery 5 times route here instead of blocking the queue.
- Message retention set to 7 days.
- Listener modified to publish events to Pub/Sub instead of writing directly to BigQuery.
- Separate subscriber worker that pulls from Pub/Sub and writes to BigQuery in micro-batches (collect for up to 2 seconds or 500 events, whichever first, then one streaming insert call).
- Resume token persistence: listener saves its resume token to a GCS file every 10 seconds. On restart, reads from GCS and resumes the change stream from that point.
- Understanding to have ready: Pub/Sub does not guarantee ordering, but this doesn't affect correctness because the BigQuery table uses MongoDB's `clusterTime` for ordering, not insertion order.

---

## Version 4 — Idempotency and Exactly-Once Semantics

**Goal:** Handle duplicate events from Pub/Sub's at-least-once delivery.

**What gets built:**
- Deduplication logic using `event_id`. Two options (implement one, explain both):
  - **Query-time dedup:** Allow duplicates in table. SQL uses `ROW_NUMBER() OVER (PARTITION BY event_id ORDER BY ingested_at) as rn` and filters `WHERE rn = 1`. Simpler, but every query pays the dedup cost.
  - **Write-time dedup:** Check for existing `event_id` before inserting, or maintain an in-memory set of recently seen event IDs in the subscriber. Harder with BigQuery streaming buffer, but more efficient at scale.
- Edge case handling in the query tool: query before snapshot returns "no data available before [snapshot time]"; nonexistent stock returns "stock not found"; BigQuery unavailable triggers retry with exponential backoff (max 5 attempts).

---

## Version 5 — Query Performance Optimization

**Goal:** Optimize query cost and latency, add richer query patterns.

**What gets built:**
- Verify partitioning (`DATE(timestamp)`) and clustering (`name`) are working — run a query with and without filters and compare bytes scanned.
- Additional query patterns in the CLI:
  - Range query: all prices of a stock between two timestamps.
  - Diff query: price change of a stock between two timestamps.
  - Latest price: most recent recorded price.
  - Snapshot query: all stock prices at a given timestamp.
- Cost estimation document with real math: rows per day at various update rates, storage cost, query cost per query, monthly total. Present as a table in the README.

---

## Version 6 — Infrastructure as Code and Setup Automation

**Goal:** Make the setup reproducible and presentable. This is what Jason follows during the live demo.

**What gets built:**
- Terraform config (or `gcloud` CLI bash script) that creates all GCP resources in one command: BigQuery dataset + tables, Pub/Sub topic + subscription + dead letter topic, GCS bucket for resume tokens, service account with least-privilege IAM roles.
- `config.yaml` template with clear placeholders: `<MONGODB_CONNECTION_STRING>`, `<GCP_PROJECT_ID>`, `<DATABASE_NAME>`, `<COLLECTION_NAME>`.
- Production-grade README with sections: prerequisites (gcloud, Terraform, Docker, Python 3.9+), step-by-step setup (authenticate, fill config, run Terraform, deploy listener, verify), troubleshooting for common issues.
- Test the README from scratch: destroy everything, follow the README as if you're Jason, confirm it works without prior knowledge. If any step takes more than 2 minutes of confusion, rewrite it.

---

## Version 7 — Containerization and Cloud Deployment

**Goal:** Move the listener from local machine to GCP. Pipeline runs in the cloud, not on your laptop.

**What gets built:**
- Dockerfile for the listener service.
- Dockerfile for the subscriber worker.
- Docker Compose file updated for local development: MongoDB replica set + listener + subscriber all together.
- Deployment scripts: push containers to Google Artifact Registry, deploy listener to Compute Engine, deploy subscriber to Cloud Run.
- Resume token storage moved from local file to GCS (if not already done in V3).
- Networking documentation: how the GCP-hosted listener connects to MongoDB depending on where MongoDB is hosted (public internet with TLS, VPN tunnel, SSH tunnel, MongoDB Atlas peering).
- The simulator is NOT containerized — it's a dev tool, never deployed.
