import json
import time
import uuid
from datetime import datetime, timezone

from bson import Timestamp
from google.cloud import bigquery, pubsub_v1, storage
from pymongo.errors import OperationFailure

import config

client = config.get_mongo_client()
db = client[config.DB_NAME]
collection = db[config.COLLECTION]

# BigQuery — metadata only (price data goes through Pub/Sub now)
bq_client = bigquery.Client(project=config.GCP_PROJECT_ID)
meta_ref  = f"{config.GCP_PROJECT_ID}.{config.BQ_DATASET}.{config.BQ_METADATA_TABLE}"

# Pub/Sub — all price events (snapshot + change stream) published here
publisher = pubsub_v1.PublisherClient()
topic_path = publisher.topic_path(config.GCP_PROJECT_ID, config.PUBSUB_TOPIC)

# GCS — resume token persistence
gcs_client = storage.Client(project=config.GCP_PROJECT_ID)


def bson_ts_to_display(ts: Timestamp) -> str:
    """Human-readable string for console output, includes ordinal counter."""
    return datetime.fromtimestamp(ts.time, tz=timezone.utc).strftime("%Y-%m-%d %H:%M:%S") + f" (ord={ts.inc})"


def bson_ts_to_iso(ts: Timestamp) -> str:
    """ISO 8601 UTC string for BigQuery TIMESTAMP columns."""
    return datetime.fromtimestamp(ts.time, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def utcnow_iso() -> str:
    return datetime.now(tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")


def write_metadata(pipeline_id: str, started_at: str, **kwargs) -> None:
    """Append one metadata row. BigQuery is append-only — updates are new rows."""
    row = {
        "pipeline_id": pipeline_id,
        "started_at": started_at,
        "snapshot_completed_at": kwargs.get("snapshot_completed_at"),
        "last_event_timestamp": kwargs.get("last_event_timestamp"),
        "last_resume_token": kwargs.get("last_resume_token"),
        "status": kwargs.get("status", "running"),
    }
    errors = bq_client.insert_rows_json(meta_ref, [row])
    if errors:
        print(f"  [META ERROR] {errors}")


def publish_event(row: dict, max_retries: int = 3) -> None:
    """Publish a price event to Pub/Sub. Retries with exponential backoff.

    Raises RuntimeError if all attempts fail — the caller should let it
    propagate so the finally block saves the last good resume token.
    """
    data = json.dumps(row).encode("utf-8")
    for attempt in range(max_retries):
        try:
            future = publisher.publish(topic_path, data=data)
            future.result(timeout=10)
            return
        except Exception as e:
            if attempt < max_retries - 1:
                wait = 2 ** attempt
                print(f"  [PUBSUB RETRY] Attempt {attempt + 1}/{max_retries} failed: {e}. Retrying in {wait}s ...")
                time.sleep(wait)
            else:
                raise RuntimeError(
                    f"Pub/Sub unavailable after {max_retries} attempts: {e}"
                ) from e


def save_resume_token(token: str) -> None:
    """Write the resume token to GCS. Overwrites on each call."""
    if not config.GCS_BUCKET:
        return
    try:
        bucket = gcs_client.bucket(config.GCS_BUCKET)
        blob = bucket.blob(config.GCS_RESUME_TOKEN_PATH)
        blob.upload_from_string(token)
    except Exception as e:
        print(f"  [GCS SAVE WARN] {e}")


def load_resume_token() -> str | None:
    """Read the resume token from GCS. Returns None if not found."""
    if not config.GCS_BUCKET:
        return None
    try:
        bucket = gcs_client.bucket(config.GCS_BUCKET)
        blob = bucket.blob(config.GCS_RESUME_TOKEN_PATH)
        token = blob.download_as_text().strip()
        return token if token else None
    except Exception:
        return None


def delete_resume_token() -> None:
    """Delete the stale resume token from GCS."""
    if not config.GCS_BUCKET:
        return
    try:
        bucket = gcs_client.bucket(config.GCS_BUCKET)
        blob = bucket.blob(config.GCS_RESUME_TOKEN_PATH)
        blob.delete()
        print("  [GCS] Deleted stale resume token")
    except Exception:
        pass


def take_snapshot(pipeline_id: str) -> Timestamp:
    """Read all documents from MongoDB and publish them to Pub/Sub as snapshot events.

    Cluster time is captured via a ping BEFORE reading documents, so any writes
    that race with the collection scan are caught by the change stream opened
    immediately after. This eliminates the snapshot-to-stream gap.

    Returns the BSON Timestamp to pass to startAtOperationTime.
    """
    print("Taking baseline snapshot ...")
    with client.start_session() as session:
        db.command("ping", session=session)
        snapshot_time: Timestamp = session.cluster_time["clusterTime"]
        docs = list(collection.find({}, session=session))

    print(f"  Snapshot time : {bson_ts_to_display(snapshot_time)}")
    print(f"  Documents     : {len(docs)}")

    rows = [
        {
            "name": doc["name"],
            "price": float(doc["price"]),
            "timestamp": bson_ts_to_iso(snapshot_time),
            "operation_type": "snapshot",
            "event_id": f"snapshot-{pipeline_id}-{doc['_id']}",
            "ingested_at": utcnow_iso(),
        }
        for doc in docs
        if "name" in doc and "price" in doc
    ]

    for row in rows:
        publish_event(row)

    print(f"  [SNAPSHOT OK] {len(rows)} events published to Pub/Sub")
    return snapshot_time


def _open_stream(saved_token: str | None, pipeline_id: str, started_at: str):
    """Decide how to open the change stream: resume from token or fresh snapshot.

    Returns (stream_context_manager, snapshot_time_or_None).
    """
    if saved_token:
        print(f"Resuming from saved token: {saved_token[:20]}...")
        return (
            collection.watch(
                full_document="updateLookup",
                resume_after={"_data": saved_token},
            ),
            None,
        )

    snapshot_time = take_snapshot(pipeline_id)
    write_metadata(
        pipeline_id,
        started_at,
        snapshot_completed_at=bson_ts_to_iso(snapshot_time),
        status="running",
    )
    return (
        collection.watch(
            full_document="updateLookup",
            start_at_operation_time=snapshot_time,
        ),
        snapshot_time,
    )


def _consume_stream(stream, snapshot_time, pipeline_id, started_at, state):
    """Read events from a change stream, publish to Pub/Sub, persist token.

    Updates `state` dict in-place so main() can read the latest values even
    if this function is interrupted by KeyboardInterrupt or RuntimeError.
    """
    event_count = 0
    last_token_save_time = time.monotonic()

    for event in stream:
        op = event.get("operationType", "unknown")
        doc = event.get("fullDocument") or {}
        name = doc.get("name", "N/A")

        # Atomic price source for update ops: use updatedFields to avoid
        # fullDocument race condition (snapshot taken after event fires —
        # a rapid second update can contaminate it with a later value).
        if op == "update":
            updated_fields = event.get("updateDescription", {}).get("updatedFields", {})
            price = updated_fields.get("price", doc.get("price"))
        else:
            price = doc.get("price")

        cluster_time = event.get("clusterTime")
        token = event["_id"]["_data"]

        ts_str = bson_ts_to_display(cluster_time) if cluster_time else "N/A"
        price_str = f"{price:.2f}" if isinstance(price, (int, float)) else "N/A"
        print(f"[{ts_str}]  {op.upper():<8}  name={name:<5}  price={price_str}  token={token}")

        if cluster_time and price is not None and name != "N/A":
            row = {
                "name": name,
                "price": float(price),
                "timestamp": bson_ts_to_iso(cluster_time),
                "operation_type": op,
                "event_id": token,
                "ingested_at": utcnow_iso(),
            }
            publish_event(row)
            print(f"  [PUBSUB OK]")

            state["last_event_ts"] = bson_ts_to_iso(cluster_time)
            state["last_token"] = token
            event_count += 1

            # Persist pipeline health on first event, then every 10
            if event_count == 1 or event_count % 10 == 0:
                write_metadata(
                    pipeline_id,
                    started_at,
                    snapshot_completed_at=bson_ts_to_iso(snapshot_time) if snapshot_time else None,
                    last_event_timestamp=state["last_event_ts"],
                    last_resume_token=state["last_token"],
                    status="running",
                )

            # Save resume token to GCS every 10 seconds
            if time.monotonic() - last_token_save_time >= 10:
                save_resume_token(state["last_token"])
                last_token_save_time = time.monotonic()


def main() -> None:
    pipeline_id = str(uuid.uuid4())
    started_at = utcnow_iso()
    snapshot_time = None

    # Mutable dict so _consume_stream can update state that survives
    # KeyboardInterrupt (the tuple-return assignment would never complete).
    state = {"last_event_ts": None, "last_token": None}

    print(f"Pipeline ID : {pipeline_id}")
    print(f"Listening on {config.DB_NAME}.{config.COLLECTION} ...")

    # Record pipeline start in metadata
    write_metadata(pipeline_id, started_at, status="running")

    saved_token = load_resume_token()

    try:
        stream_ctx, snapshot_time = _open_stream(saved_token, pipeline_id, started_at)

        # collection.watch() is lazy — OperationFailure for a stale token fires
        # on first iteration, not on watch(). Wrap with __enter__ to detect it.
        with stream_ctx as stream:
            try:
                _consume_stream(stream, snapshot_time, pipeline_id, started_at, state)
            except OperationFailure:
                if not saved_token:
                    raise  # not a stale-token issue, re-raise
                print("  [WARN] Saved token is stale (oplog rolled past). Falling back to fresh snapshot.")
                delete_resume_token()

                stream_ctx2, snapshot_time = _open_stream(None, pipeline_id, started_at)
                with stream_ctx2 as stream2:
                    _consume_stream(stream2, snapshot_time, pipeline_id, started_at, state)

    except KeyboardInterrupt:
        print("\nListener stopped.")
    except RuntimeError as e:
        print(f"\n[FATAL] {e}")
        print("Listener will resume from last saved token on restart.")

    finally:
        if state["last_token"]:
            save_resume_token(state["last_token"])
        write_metadata(
            pipeline_id,
            started_at,
            snapshot_completed_at=bson_ts_to_iso(snapshot_time) if snapshot_time else None,
            last_event_timestamp=state["last_event_ts"],
            last_resume_token=state["last_token"],
            status="stopped",
        )


if __name__ == "__main__":
    main()
