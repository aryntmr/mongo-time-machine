# Vali Health CDC Pipeline

MongoDB → Pub/Sub → BigQuery change-data-capture pipeline with point-in-time stock price queries. Captures every price update via MongoDB change streams, fans out through Pub/Sub, and lands in BigQuery for historical queries.

---

## Architecture

```
[Your app / simulator.py]  →  MongoDB replica set
                                      │
                          listener.py (Docker container, local machine)
                                      │   saves resume token → GCS
                                   Pub/Sub
                          (60s ack deadline · 7-day retention · dead letter after 5 fails)
                                      │
                          subscriber.py (Cloud Run, min 1 instance)
                                      │
                           BigQuery — price_history (deduped at query time by event_id)

listener.py  →  pipeline_metadata (direct BQ writes)
            →  resume token (GCS, saved every 10s + on shutdown)
```

---

## Prerequisites

- [Docker Desktop](https://docs.docker.com/get-docker/) — the only thing you need to install
- A GCP project with **billing enabled**
- A MongoDB **replica set** (standalone MongoDB does not support change streams)

All other tools (gcloud CLI, Terraform, Python) run inside the tools container — nothing else to install.

---

## Setup

**1. Configure**
```bash
cd src
cp config.yaml.example config.yaml
```
Edit `config.yaml` — fill in your GCP project ID and MongoDB connection details.

**2. Bootstrap** — provisions all GCP infrastructure and writes `.env`
```bash
make bootstrap
```
Enables GCP APIs, runs Terraform (BigQuery, Pub/Sub, GCS, Artifact Registry, Cloud Run, service account), and writes `service-account-key.json`. Will prompt for browser-based Google login on first run or when switching accounts.

**3. Deploy subscriber to Cloud Run**
```bash
make deploy
```
Builds the subscriber image for `linux/amd64`, pushes to Artifact Registry, and deploys to Cloud Run with min 1 instance so it's always ready to pull from Pub/Sub.

**4. Start local MongoDB**
```bash
make up
```
Starts a 3-node MongoDB replica set in Docker. Skip this step if you're connecting to your own MongoDB (Atlas or on-prem) — set `MONGO_URI` in `config.yaml` instead.

**5. Start the listener**
```bash
make listener-up
```
Starts the listener as a Docker container. It takes a baseline snapshot of your MongoDB collection, then watches the change stream and publishes every update to Pub/Sub. The Cloud Run subscriber picks them up and writes to BigQuery.

**6. Verify** (wait ~30s for BigQuery streaming buffer to settle)
```bash
make validate                              # MongoDB == BigQuery?
make query ARGS='--name AAPL --latest'     # latest price
make query ARGS='--name AAPL --time "2026-03-29 12:05:30"'   # price at a point in time
make query ARGS='--all-at-time "2026-03-29 12:05:30"'        # all stocks at a point in time
```

---

## Connecting to Your Own MongoDB

Set `mongodb.connection_string` in `config.yaml` before running `make bootstrap`:

```yaml
mongodb:
  connection_string: mongodb+srv://<user>:<pass>@<cluster>.mongodb.net/
  database: <your-database>
  collection: <your-collection>
```

**Requirements:**
- MongoDB must be a **replica set** — change streams do not work on standalone instances
- The listener container connects outbound from your machine — no inbound firewall rules needed
- For MongoDB Atlas: whitelist your IP (or `0.0.0.0/0` for demos) in Atlas Network Access

---

## Running the Simulator (optional, for testing)

```bash
make simulate
```
Generates random price updates to the local Docker MongoDB. Not needed when connected to a real database.

---

## Querying

```bash
make query ARGS='--name AAPL --latest'
make query ARGS='--name AAPL --time "2026-03-29 12:05:00"'
make query ARGS='--all-at-time "2026-03-29 12:05:00"'
```

---

## Validation

Compares every document in MongoDB against the latest state in BigQuery.

```bash
make validate   # exit 0 = all OK · exit 1 = MISSING or MISMATCH
```

---

## Tear Down

```bash
make listener-down       # stop listener container
make down                # stop MongoDB, remove volumes
make infra-destroy       # destroy all GCP resources via Terraform
```

---

## Troubleshooting

**`PRIMARY not found` on startup**
MongoDB replica set election takes 10–20s. Check logs: `docker compose logs mongo-setup`. Wait and re-run `make listener-up`.

**`make bootstrap` prompts for login even though you're already logged in**
Your current Google account doesn't have access to the GCP project in `config.yaml`. Bootstrap detects this and prompts you to log in with the correct account.

**`terraform apply` fails with "already exists"**
Re-running `make bootstrap` handles this automatically — it imports the existing resource and retries.

**Switching to a new GCP project**
Update `gcp.project_id` in `config.yaml` and re-run `make bootstrap`. Bootstrap detects the project change, clears stale Terraform state, and provisions fresh.

**`make validate` reports MISMATCH**
BigQuery streaming inserts have up to 30s delay. Wait ~30s after the last write and re-run. If your database is updating rapidly the values may legitimately differ between the two reads.

**Resume token stale after MongoDB restart**
The listener detects this automatically (`OperationFailure`), deletes the stale token from GCS, and performs a fresh snapshot on the next start.

**`exec format error` on Cloud Run**
The subscriber image was built for the wrong CPU architecture (e.g. ARM64 on an M1 Mac). `make deploy` uses `--platform linux/amd64` to build AMD64 images regardless of host architecture — re-running `make deploy` fixes this.

**No billing account**
Terraform cannot enable GCP APIs without billing. Enable billing on the project at console.cloud.google.com before running `make bootstrap`.
