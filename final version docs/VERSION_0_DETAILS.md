# Version 0: Implementation Details

## Dependencies

### System (install once)
- **Docker Desktop** — MongoDB runs inside containers, no local install needed
- **Python 3.9+**

### Python packages
```
pymongo>=4.0
python-dotenv>=1.0
```
`python-dotenv` loads `.env` so config never lives in code.

---

## Folder Structure

```
src/
├── docker-compose.yml       # 3-node MongoDB replica set
├── mongo-init/
│   └── init.sh              # rs.initiate() + seed data (runs once on first up)
├── simulator.py             # mock price updater
├── listener.py              # change stream listener
├── config.py                # all config in one place, reads from .env
├── requirements.txt         # pymongo, python-dotenv
├── .env.example             # template — commit this
├── .env                     # actual values — never commit this
├── .gitignore
└── Makefile                 # shortcuts: make up, make listen, make simulate
```

### Why this layout
- **`config.py`** — single source of truth for every setting. Both `simulator.py` and `listener.py` import from it. No magic strings scattered across files.
- **`.env` / `.env.example`** — config is separated from code. `.env.example` is committed as a template; `.env` holds real values and is gitignored.
- **`Makefile`** — wraps common commands so you don't have to remember long Docker or Python invocations.
- **Flat Python files** — this is a PoC, not a library. No nesting needed. Keep it simple.
- **`mongo-init/` subfolder** — init script is infrastructure concern, not application code. Isolated from the Python layer.

---

## File Details

### `.env.example`
```env
MONGO_URI=mongodb://host.docker.internal:27017,host.docker.internal:27018,host.docker.internal:27019/?replicaSet=rs0
DB_NAME=stockdb
COLLECTION=stocks
UPDATE_INTERVAL=1.0
BURSTY_MODE=false
BURSTY_MIN=0.1
BURSTY_MAX=3.0
```

### `config.py`
```python
import os
import socket
import pymongo
from dotenv import load_dotenv

load_dotenv()

MONGO_URI       = os.getenv("MONGO_URI", "mongodb://host.docker.internal:27017,host.docker.internal:27018,host.docker.internal:27019/?replicaSet=rs0")
DB_NAME         = os.getenv("DB_NAME", "stockdb")
COLLECTION      = os.getenv("COLLECTION", "stocks")
UPDATE_INTERVAL = float(os.getenv("UPDATE_INTERVAL", "1.0"))
BURSTY_MODE     = os.getenv("BURSTY_MODE", "false").lower() == "true"
BURSTY_MIN      = float(os.getenv("BURSTY_MIN", "0.1"))
BURSTY_MAX      = float(os.getenv("BURSTY_MAX", "3.0"))


def get_mongo_client() -> pymongo.MongoClient:
    # Tries MONGO_URI first. If hostname resolution fails (common on macOS when
    # host.docker.internal is not in /etc/hosts), falls back to scanning
    # localhost:27017-27019 with directConnection to find the current PRIMARY.
    try:
        from urllib.parse import urlparse
        host = urlparse(MONGO_URI.split(",")[0].replace("mongodb://", "http://")).hostname or ""
        socket.getaddrinfo(host, None)
        client = pymongo.MongoClient(MONGO_URI, serverSelectionTimeoutMS=3000)
        client.admin.command("ping")
        return client
    except Exception:
        pass

    for port in [27017, 27018, 27019]:
        try:
            client = pymongo.MongoClient(
                f"mongodb://localhost:{port}/?directConnection=true",
                serverSelectionTimeoutMS=1000,
            )
            if client.admin.command("hello").get("isWritablePrimary"):
                return client
            client.close()
        except Exception:
            pass

    raise RuntimeError(
        "Could not connect to MongoDB. Is the replica set running? Try: make up"
    )
```

### `.gitignore`
```
.env
__pycache__/
*.pyc
```

### `Makefile`
```makefile
up:
	docker compose up -d

down:
	docker compose down -v

logs:
	docker compose logs -f

listen:
	python listener.py

simulate:
	python simulator.py

install:
	pip install -r requirements.txt
```

### `requirements.txt`
```
pymongo>=4.0
python-dotenv>=1.0
```

---

## `docker-compose.yml` — What to Build

- Services: `mongo1` (port 27017), `mongo2` (27018), `mongo3` (27019) — **all 3 ports must be exposed** on the host so the Python driver can reach every member
- All use replica set name `rs0`
- A short-lived `mongo-setup` container:
  - Waits for `mongo1` to accept connections (health check loop)
  - Calls `mongosh` to run `rs.initiate()` with members using **`host.docker.internal` addresses** (`host.docker.internal:27017`, `host.docker.internal:27018`, `host.docker.internal:27019`) — this is required so both the containers (for intra-replica-set communication) and pymongo on the host machine can resolve the members
  - Waits for PRIMARY election
  - Seeds 5 stocks: AAPL (150), GOOG (140), TSLA (250), AMZN (185), MSFT (380) — using `upsert: true` so re-runs are safe
- `mongo-setup` mounts `./mongo-init/init.sh` and exits after seeding

### Healthcheck for sequencing
```yaml
healthcheck:
  test: mongosh --eval "db.adminCommand('ping')"
  interval: 5s
  retries: 10
```

---

## `mongo-init/init.sh` — What to Build

1. Poll `mongo1:27017` with `mongosh --eval "db.adminCommand('ping')"` until it responds
2. Call `rs.initiate()` with members defined as `host.docker.internal:27017`, `host.docker.internal:27018`, `host.docker.internal:27019` — not `localhost` (breaks inside containers) and not container names (breaks from the host)
3. Poll until `rs.status()` shows a PRIMARY
4. Insert seed documents into `stockdb.stocks` with `updateOne + upsert: true`

---

## `simulator.py` — What to Build

- Import config from `config.py`
- Connect via `config.get_mongo_client()`
- Load all docs from `COLLECTION` into a local price dict on startup
- Exit cleanly with a message if the collection is empty (no crash on `random.choice([])`)
- Loop:
  - Pick a random stock
  - Compute `new_price = old_price + random.uniform(-2, 2)`, floor at 1.0
  - `update_one({"name": stock}, {"$set": {"price": new_price}})`
  - Print: `[TIMESTAMP] UPDATE  AAPL  149.83 → 151.20`
  - Sleep: `random.uniform(BURSTY_MIN, BURSTY_MAX)` if `BURSTY_MODE` else `UPDATE_INTERVAL`

---

## `listener.py` — What to Build

- Import config from `config.py`
- Connect via `config.get_mongo_client()`
- Open change stream on `db[COLLECTION]` with `full_document="updateLookup"`
- For each event, extract and print a structured line:
  ```
  [clusterTime (ord=N)]  UPDATE  name=AAPL  price=151.20  token=<resume_token_id>
  ```
- Also record `wallTime` from the event (datetime, ms precision) for future use
- `clusterTime` is a BSON Timestamp: `.time` is Unix seconds, `.inc` is an ordinal counter for ordering within the same second — not a fractional second
- `wallTime` is the actual wall clock datetime at commit time (millisecond precision, MongoDB 4.2+)
- Handle empty collection gracefully (no crash)
- On `KeyboardInterrupt`, exit cleanly

---

## Verification Steps

```bash
make install        # install Python deps
make up             # start 3-node replica set + run init script
# wait ~10-15s for replica set to elect a PRIMARY
docker compose logs mongo-setup   # confirm: PRIMARY elected + Seeded 5 stocks

make listen         # terminal 1 — sits idle waiting for events

make simulate       # terminal 2 — starts printing price updates
```

**Check:**
- Every simulator update appears in the listener output
- `clusterTime` shows as `YYYY-MM-DD HH:MM:SS (ord=N)`
- The order of events in the listener matches the order of updates from the simulator
- Rapid updates to the same stock appear as separate events (no coalescing)
- Stopping the simulator (Ctrl+C) leaves the listener running and idle (no crash)
