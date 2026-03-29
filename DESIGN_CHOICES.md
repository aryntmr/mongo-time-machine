# Architecture & Design Document

## Architecture Overview

```
┌─────────────────────┐
│   MongoDB            │
│   (Source DB)        │
│   name | price       │
└──────────┬──────────┘
           │ Change Stream (real-time CDC)
           ▼
┌─────────────────────┐
│   Listener Service   │
│   (Compute Engine)   │
│   - Captures events  │
│   - Persists resume  │
│     token to GCS     │
│   - Takes initial    │
│     snapshot on      │
│     startup          │
└──────────┬──────────┘
           │ Publishes events
           ▼
┌─────────────────────┐
│   Google Pub/Sub     │
│   - Buffers events   │
│   - Dead letter      │
│     topic for        │
│     failed messages  │
└──────────┬──────────┘
           │ Pulls and batches
           ▼
┌─────────────────────┐
│   Subscriber Worker  │
│   (Cloud Run)        │
│   - Micro-batches    │
│     writes           │
│   - Deduplication    │
└──────────┬──────────┘
           │ Streaming inserts
           ▼
┌─────────────────────┐
│   BigQuery           │
│   (Historical Store) │
│   - Partitioned by   │
│     date             │
│   - Clustered by     │
│     name             │
└──────────┬──────────┘
           │ Point-in-time SQL
           ▼
┌─────────────────────┐
│   Query Interface    │
│   - Python CLI       │
│   - Cloud Run API    │
│     (optional)       │
└─────────────────────┘
```

## Data Flow

1. An external application writes/updates prices in the source MongoDB collection.
2. The listener service holds a persistent connection to MongoDB via a change stream, receiving every write event in real time.
3. On first startup, the listener snapshots the entire current state of the collection as a baseline before opening the change stream.
4. Each captured event is published to a Pub/Sub topic with the MongoDB cluster timestamp (the moment MongoDB committed the write).
5. A subscriber worker pulls events from Pub/Sub, micro-batches them, and writes to BigQuery.
6. The query interface accepts a stock name and timestamp, runs a point-in-time SQL query against BigQuery, and returns the exact price.

---

## Stack Choices and Reasoning

### Change Data Capture: MongoDB Change Streams

**What it is:** A MongoDB feature that lets you subscribe to real-time notifications of every write operation on a collection.

**Why chosen:**
- Captures every individual write — no data loss between reads (unlike polling).
- Provides the MongoDB cluster timestamp — the exact moment the write was committed.
- Non-invasive — no modifications to the source database or application.
- Sub-second latency from write to event delivery.

**Alternatives considered:**

| Approach | Pros | Cons | Why not chosen |
|----------|------|------|----------------|
| Polling | Works on any MongoDB setup, simple to implement | Misses intermediate changes between polls, puts read load on source DB, loses granularity | Jason said "as granular as possible" — polling can't guarantee that |
| Application-level hooks | Perfect accuracy, full control | Requires modifying the source application | Jason said "don't make changes to the database" |
| GCP Datastream | Managed CDC service, less code to write | Turnkey solution — Jason said AWS "makes it too easy," same concern applies to managed CDC on GCP | Doesn't demonstrate engineering understanding |

**Prerequisite:** Change streams require MongoDB 3.6+ running as a replica set.

**Risk:** If the listener goes down and the oplog rolls past unread events, those events are lost forever. Mitigation: resume token persistence and periodic snapshot reconciliation.

---

### Storage: BigQuery

**What it is:** GCP's serverless, columnar analytical data warehouse.

**Why chosen:**
- Jason said he wants an "offline data store" for historical queries — BigQuery is exactly this.
- Serverless — no instance sizing, no disk management, no capacity planning.
- Scales to petabytes without any configuration changes.
- SQL interface — the point-in-time query is a simple SQL statement.
- Near-zero storage cost ($0.02/GB/month, data compresses well).
- Native GCP service — aligns with Jason's GCP-only constraint.
- Supports partitioning and clustering for query performance and cost optimization.

**Alternatives considered:**

| Store | Pros | Cons | Why not chosen |
|-------|------|------|----------------|
| Cloud SQL (PostgreSQL) | Faster point lookups (milliseconds vs seconds), B-tree index on (name, timestamp) is efficient | Requires instance management, must pick a size, pays for idle capacity, OLTP system for an OLAP problem | Jason's use case is historical/analytical — "offline data store" and "analytics" point to OLAP, not OLTP |
| Cloud Bigtable | Millisecond lookups, purpose-built for time-series, handles massive write throughput | Minimum ~$470/month for one node, overkill for this scale | Cost disproportionate to the problem. Correct choice at very high scale. |
| Firestore | Serverless, real-time, cheap at low scale | "Latest price where timestamp <= T" is awkward to query, not designed for analytical time-range queries | Wrong data model for this query pattern |
| GCS + Parquet files | Cheapest storage, no database to manage | No query engine without BigQuery external tables (which is just BigQuery with extra steps) | Adds complexity without benefit |

**Known tradeoff:** BigQuery has 1-3 second query latency for point lookups. This is acceptable for historical queries. If sub-100ms latency is needed in future, add a Cloud SQL or Redis cache in front of BigQuery for hot queries while keeping BigQuery as source of truth.

**Schema:**

```sql
name:           STRING    -- stock/company name
price:          FLOAT64   -- price at time of change
timestamp:      TIMESTAMP -- MongoDB clusterTime (when the write was committed)
operation_type: STRING    -- insert/update/replace/snapshot
event_id:       STRING    -- change stream resume token (natural dedup key)
ingested_at:    TIMESTAMP -- when the pipeline processed the event (for lag monitoring)
```

**Table configuration:**
- Partitioned by `DATE(timestamp)` — queries for a specific date only scan that partition.
- Clustered by `name` — queries for a specific stock scan only that stock's data within the partition.
- These reduce both query cost and latency significantly at scale.

---

### Message Queue: Google Cloud Pub/Sub

**What it is:** GCP's managed publish-subscribe messaging service.

**Why chosen:**
- Decouples the listener from the BigQuery writer — if BigQuery slows down or errors, events are safely buffered in Pub/Sub instead of being lost.
- At-least-once delivery with automatic retries.
- Dead letter topic support — failed messages are set aside instead of blocking the queue.
- Serverless, no capacity management.
- Native GCP service.

**Alternatives considered:**

| Queue | Pros | Cons | Why not chosen |
|-------|------|------|----------------|
| No queue (direct writes) | Simpler, fewer moving parts | If BigQuery write fails, event is lost; listener backs up if writes are slow | Acceptable for MVP but not production-grade |
| Kafka on GKE | Stronger ordering, replay capability, higher throughput | Massive operational overhead, overkill for this volume | Disproportionate complexity |

**Key detail:** Pub/Sub does not guarantee message ordering. This is acceptable because the BigQuery table records the MongoDB cluster timestamp on each event. The point-in-time query uses this timestamp for ordering, not insertion order. Out-of-order delivery does not affect query correctness.

**Configuration decisions:**
- Pull subscription (not push) — gives control over batch size and processing rate.
- Message retention: 7 days — buffer against extended subscriber downtime.
- Acknowledgment deadline: 60 seconds.
- Dead letter topic: after 5 failed deliveries, message routes to DLQ for investigation.

---

### Listener Host: Compute Engine

**What it is:** A GCP virtual machine.

**Why chosen:**
- The change stream listener holds a persistent TCP connection to MongoDB. This is a long-lived process, not a request-response pattern.
- Compute Engine supports always-on, long-running processes natively.

**Alternatives considered:**

| Host | Pros | Cons | Why not chosen |
|------|------|------|----------------|
| Cloud Run | Serverless, scales to zero, no OS management | Designed for request-driven workloads; long-lived connections fight the model | Persistent connection to MongoDB doesn't fit Cloud Run's design |
| Cloud Functions | Serverless, event-driven | Max execution time of 9 minutes (2nd gen); cannot hold a persistent connection | Hard timeout makes it impossible for continuous listening |
| GKE Autopilot | Auto-restart on crash, container orchestration, no node management | Adds Kubernetes complexity, minimum cluster cost | Better production choice, but adds setup complexity for a take-home |

**Production note:** In a production deployment, GKE Autopilot is the better choice — Kubernetes automatically restarts crashed pods and handles scheduling. For the take-home, Compute Engine keeps setup simpler.

---

### Query Interface: Python CLI + Cloud Run API (optional)

**Why CLI first:**
- Jason said "when we meet, we're going to try this on this database." A CLI is the fastest way to demo a query live.
- No additional deployment needed — just run `python query.py --name AAPL --time "2026-03-27 12:05:53"`.
- Easy to debug during live demo.

**Why Cloud Run API as optional add-on:**
- Provides an HTTP endpoint for programmatic access.
- More useful for actual application integration.
- Demonstrates full-stack thinking.

**Point-in-time query SQL:**

```sql
SELECT price, timestamp
FROM `project.dataset.price_history`
WHERE name = @name
  AND timestamp <= @target_time
ORDER BY timestamp DESC
LIMIT 1
```

This returns the most recent price update at or before the requested timestamp — the price that was "effective" at that moment.

---

### Infrastructure as Code: Terraform or gcloud CLI script

**Decision:** Use whichever can be executed faster. Both achieve the same outcome — reproducible, automated GCP resource creation.

- **Terraform:** Industry standard, declarative, tracks state, supports teardown. Better if already familiar.
- **gcloud CLI bash script:** Imperative, no state tracking, but faster to write if not familiar with Terraform. Every command is copy-pasteable by Jason.

---

### Language: Python

**Why:** First-class support for `pymongo` (MongoDB driver with change streams), `google-cloud-bigquery`, `google-cloud-pubsub`, and `google-cloud-storage`. Data infrastructure is Python-dominant in the industry.

---

## Key Design Decisions

### 1. Timestamp Authority: MongoDB clusterTime

The pipeline records the MongoDB cluster timestamp (when the write was committed in MongoDB), NOT the time the pipeline received or processed the event. This is critical because network delays or pipeline lag would make historical data inaccurate if ingestion time were used instead.

The `ingested_at` field is stored separately for monitoring pipeline lag (the delta between `timestamp` and `ingested_at`).

### 2. Initial Snapshot on Startup

Before opening the change stream, the listener reads the entire current state of the MongoDB collection and writes it to BigQuery with `operation_type: "snapshot"`. This serves as the baseline. Without this, the first query would return nothing.

The change stream is then opened using `startAtOperationTime` aligned to the snapshot time, ensuring no gap between the snapshot and the first change event. This may produce duplicates (an event captured in both the snapshot and the change stream), which are handled by deduplication.

### 3. Resume Token Persistence

After every batch of events, the listener saves its change stream resume token to GCS. On restart, it reads this token and resumes the change stream from where it left off. This prevents data loss on crashes.

Risk: if the listener is down long enough for the MongoDB oplog to roll past the resume token's position, the token becomes invalid and events in that gap are lost. Mitigation: size the oplog for expected maximum downtime, and run periodic reconciliation.

### 4. Append-Only Storage

The BigQuery table never updates or deletes rows. Every price change is a new row. This means bugs or failures can never corrupt historical data — the worst case is missing rows or duplicates, both of which are detectable and fixable.

### 5. Deduplication Strategy

Pub/Sub provides at-least-once delivery, meaning the same event can arrive more than once. The `event_id` field (derived from the change stream resume token) is a natural deduplication key. Dedup can be done at query time (using SQL `ROW_NUMBER()` windowing) or at write time (checking for existing event_id before inserting). Query-time dedup is simpler to implement; write-time dedup is more efficient at scale.

### 6. Gap Detection and Data Integrity

A metadata table tracks pipeline state: when the listener started, when the snapshot was taken, the last event timestamp, and any detected gaps. The query tool checks this before returning results — if the requested timestamp falls in a known gap, it warns the user instead of silently returning stale data. This directly addresses Jason's requirement for exact accuracy.

A reconciliation script compares the current MongoDB state against the latest state implied by BigQuery event history to verify no events were missed.

---

## Scalability Considerations

**Current design handles:** Hundreds of updates per second across all stocks. This covers typical application-level update rates.

**If scale increases:**

| Bottleneck | Sign | Solution |
|------------|------|----------|
| Listener can't keep up with change stream volume | Events lag behind, Pub/Sub backlog grows | Run multiple listeners, each watching a subset of the collection (sharded by document ID or namespace) |
| BigQuery streaming insert limits | Write errors, quota exceeded | Switch to micro-batch load jobs, or move to Bigtable for write-heavy workloads |
| BigQuery query latency too high | Queries take >3 seconds | Add Cloud SQL or Redis cache for hot lookups, keep BigQuery as source of truth |
| Single collection limit | Need to track history on multiple collections | Parameterize the listener config to accept a list of collections; each gets its own BigQuery table or a unified table with a `collection_name` column |

---

## Cost Estimation (Rough)

Assuming 500 stocks, 1 update per second each:
- **Events per day:** ~43 million rows
- **Raw data size per day:** ~2 GB uncompressed
- **BigQuery storage:** ~$0.04/month (compressed, after first 10GB free)
- **BigQuery streaming inserts:** ~$0.20/day ($0.01 per 200 MB)
- **Pub/Sub:** pennies/day at this volume
- **Compute Engine (e2-micro):** ~$7.50/month
- **GCS (resume tokens):** negligible
- **Total:** under $20/month at moderate scale
