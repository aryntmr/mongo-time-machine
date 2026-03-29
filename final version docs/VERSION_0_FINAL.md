# Version 0: Local Proof of Concept

## Goal

Prove that the core CDC loop works locally: MongoDB updates trigger change stream events that the listener catches in real time with accurate timestamps.

## What Was Built

### 1. Docker Compose — Local MongoDB Replica Set

A 3-node MongoDB replica set running in Docker. All 3 ports are exposed on the host (27017, 27018, 27019) because pymongo discovers all replica set members from the topology and needs to reach each one directly.

An init container (`mongo-setup`) runs once on first `docker compose up`:
- Polls `mongo1:27017` until it responds.
- Calls `rs.initiate()` with members registered as `host.docker.internal:27017/18/19`. This address works from both inside containers (for intra-replica-set communication) and from the host machine.
- Polls until a PRIMARY is elected. Any of the 3 nodes may win — the election is non-deterministic.
- Seeds 5 stocks into `stockdb.stocks` using `upsert: true`: AAPL (150), GOOG (140), TSLA (250), AMZN (185), MSFT (380).

### 2. `config.py`

Single source of truth for all settings. Reads from `.env` via `python-dotenv`. Exposes a `get_mongo_client()` function that:
- Does a fast DNS check on the hostname in `MONGO_URI` before attempting a connection.
- If it resolves, connects using the full replica set URI.
- If not (common on macOS where `host.docker.internal` is absent from `/etc/hosts`), falls back to scanning `localhost:27017/18/19` with `directConnection=true` to find the current PRIMARY.
- Raises a `RuntimeError` with a clear message if no primary is found.

Config variables:

| Variable | Default | Description |
|---|---|---|
| `MONGO_URI` | `mongodb://host.docker.internal:27017,.../?replicaSet=rs0` | Replica set connection string |
| `DB_NAME` | `stockdb` | Database name |
| `COLLECTION` | `stocks` | Collection name |
| `UPDATE_INTERVAL` | `1.0` | Seconds between simulator updates |
| `BURSTY_MODE` | `false` | If true, uses random sleep instead of fixed interval |
| `BURSTY_MIN` | `0.1` | Minimum sleep seconds in bursty mode |
| `BURSTY_MAX` | `3.0` | Maximum sleep seconds in bursty mode |

### 3. Simulator (`simulator.py`)

On startup, connects via `config.get_mongo_client()` and loads all documents from the collection into a local `{name: price}` dict. Exits with a clear error message if the collection is empty.

Runs an infinite loop:
- Picks a random stock.
- Computes `new_price = old_price + random.uniform(-2, 2)`, floored at `1.0`.
- Calls `update_one({"name": stock}, {"$set": {"price": new_price}})`.
- Prints: `[TIMESTAMP] UPDATE  AAPL  149.83 → 151.20`.
- Sleeps `random.uniform(BURSTY_MIN, BURSTY_MAX)` if `BURSTY_MODE`, else `UPDATE_INTERVAL`.

Exits cleanly on `KeyboardInterrupt`.

### 4. Listener (`listener.py`)

Connects via `config.get_mongo_client()` and opens a change stream on the collection with `full_document="updateLookup"`.

For each event:
- Extracts `operationType`, `name` and `price` from `fullDocument`, `clusterTime`, `wallTime`, and the resume token from `_id._data`.
- Prints a structured line:
  ```
  [2026-03-29 03:38:19 (ord=1)]  UPDATE    name=AAPL   price=151.20  token=...
  ```
- `clusterTime` is a BSON Timestamp: `.time` is Unix seconds, `.inc` is an ordinal counter for ordering events within the same second — not a fractional second.
- `wallTime` is the actual wall clock datetime at commit time with millisecond precision (MongoDB 4.2+). Recorded as a variable for future use.
- `price` is read from `fullDocument`. Note: `fullDocument` with `updateLookup` is a snapshot taken after the event fires — under rapid updates it may reflect a later write. The atomic source for price is `updateDescription.updatedFields["price"]`, recorded directly in the oplog at commit time.

Handles an empty collection gracefully — the change stream waits for events without crashing. Exits cleanly on `KeyboardInterrupt`.

## Dependencies

```
pymongo>=4.0
python-dotenv>=1.0
```

## Verification

```bash
# From src/
docker compose up -d
docker compose logs mongo-setup   # confirm: PRIMARY elected + Seeded 5 stocks

python listener.py   # terminal 1 — idles waiting for events
python simulator.py  # terminal 2 — starts printing price updates
```

Verified:
- Every simulator update appears in the listener output.
- Event order matches update order.
- Rapid updates to the same stock appear as separate events (no coalescing).
- Stopping the simulator leaves the listener running idle — no crash.

## What This Version Does Not Include

- No GCP, no BigQuery, no Pub/Sub, no GCS.
- No resume token persistence — listener starts fresh each time.
- No initial snapshot.
- No query interface.
- No deduplication.
- No error retry on failed writes.
