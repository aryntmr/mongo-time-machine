# Version 0: Local Proof of Concept

## Goal

Prove that the core CDC loop works locally: MongoDB updates trigger change stream events that our listener catches in real time with accurate timestamps.

## What to Build

### 1. Docker Compose — Local MongoDB Replica Set

- 3-node MongoDB replica set (not standalone, not single node).
- Expose port 27017 on the primary.
- Include an init script that:
  - Waits for all nodes to be ready.
  - Runs `rs.initiate()` with the 3-node config.
  - Creates the `stockdb` database and `stocks` collection.
  - Seeds initial documents: at least 5 stocks (e.g., AAPL, GOOG, TSLA, AMZN, MSFT) with starting prices.

### 2. Mock Simulator Script (`simulator.py`)

- Connects to the local MongoDB replica set.
- Configurable `UPDATE_INTERVAL` (seconds between updates).
- On each tick:
  - Picks a random stock from the collection.
  - Applies a random walk price change (small delta, not wild jumps — e.g., `current_price + random.uniform(-2, 2)`).
  - Updates the document in place using `update_one`.
- Also supports erratic/bursty mode: replace fixed interval with `random.uniform(min, max)` sleep.
- Prints each update to console: stock name, old price, new price, timestamp.

### 3. Change Stream Listener (`listener.py`)

- Connects to the local MongoDB replica set.
- Opens a change stream on the `stocks` collection with `full_document="updateLookup"` (this returns the full document on every update, not just the changed fields).
- For each event received, extract and print:
  - `name` — from the full document.
  - `price` — from the full document.
  - `clusterTime` — the MongoDB timestamp when the write was committed.
  - `operationType` — insert, update, replace.
  - `_id` of the change event (this is the resume token).
- Log output should be structured (not just raw dict dumps) so it's easy to verify correctness.

### 4. Verification Test

- Start the replica set with `docker-compose up`.
- Run the listener in one terminal.
- Run the simulator in another terminal.
- Confirm:
  - Every update from the simulator appears in the listener output.
  - The `clusterTime` is sub-second precision.
  - The order of events matches the order of updates.
  - Multiple rapid updates to the same stock all appear as separate events (no coalescing).
  - When the simulator stops, the listener stays connected and idle (no crash, no timeout).

## Things to Get Right at This Step

- Use `full_document="updateLookup"` — without this, update events only contain the delta (changed fields), not the full document. We need the full `name` and `price` on every event.
- Connect to the replica set URI (`mongodb://mongo1:27017,mongo2:27018,mongo3:27019/?replicaSet=rs0`), not a single node URI.
- The listener should handle the case where the collection is empty on startup (no crash).
- The simulator should use `upsert=True` on the initial seed so re-running it doesn't fail on duplicates.

## Dependencies

```
pymongo>=4.0
```

## What This Version Does NOT Include

- No GCP, no BigQuery, no Pub/Sub, no GCS.
- No resume token persistence (listener starts fresh each time).
- No snapshot logic.
- No query interface.
- No error handling beyond basic connection failures.
