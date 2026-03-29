import uuid
from datetime import datetime, timezone

from bson import Timestamp
from google.cloud import bigquery

import config

client = config.get_mongo_client()
db = client[config.DB_NAME]
collection = db[config.COLLECTION]

bq_client = bigquery.Client(project=config.GCP_PROJECT_ID)
table_ref = f"{config.GCP_PROJECT_ID}.{config.BQ_DATASET}.{config.BQ_TABLE}"
meta_ref  = f"{config.GCP_PROJECT_ID}.{config.BQ_DATASET}.{config.BQ_METADATA_TABLE}"


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


def take_snapshot(pipeline_id: str) -> Timestamp:
    """Read all documents from MongoDB and write them to BigQuery as snapshot rows.

    Cluster time is captured via a ping BEFORE reading documents, so any writes
    that race with the collection scan are caught by the change stream opened
    immediately after. This eliminates the snapshot-to-stream gap.

    Returns the BSON Timestamp to pass to startAtOperationTime.
    """
    print("Taking baseline snapshot ...")
    with client.start_session() as session:
        # Ping first to advance session's cluster_time before the find.
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

    if rows:
        errors = bq_client.insert_rows_json(table_ref, rows)
        if errors:
            print(f"  [SNAPSHOT BQ ERROR] {errors}")
        else:
            print(f"  [SNAPSHOT OK] {len(rows)} rows written")

    return snapshot_time


def main() -> None:
    pipeline_id = str(uuid.uuid4())
    started_at = utcnow_iso()
    event_count = 0
    last_event_ts = None
    last_token = None

    print(f"Pipeline ID : {pipeline_id}")
    print(f"Listening on {config.DB_NAME}.{config.COLLECTION} ...")

    # Record pipeline start in metadata
    write_metadata(pipeline_id, started_at, status="running")

    # Baseline snapshot — establishes cluster time anchor
    snapshot_time = take_snapshot(pipeline_id)
    write_metadata(
        pipeline_id,
        started_at,
        snapshot_completed_at=bson_ts_to_iso(snapshot_time),
        status="running",
    )

    try:
        # Open change stream from the snapshot's cluster time — no gap.
        # Events that overlap with the snapshot are written as duplicates;
        # deduplication by event_id is handled in Version 4.
        with collection.watch(
            full_document="updateLookup",
            start_at_operation_time=snapshot_time,
        ) as stream:
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
                    errors = bq_client.insert_rows_json(table_ref, [row])
                    if errors:
                        print(f"  [BQ ERROR] {errors}")
                    else:
                        print(f"  [BQ OK]")

                    last_event_ts = bson_ts_to_iso(cluster_time)
                    last_token = token
                    event_count += 1

                    # Persist pipeline health on first event, then every 10
                    if event_count == 1 or event_count % 10 == 0:
                        write_metadata(
                            pipeline_id,
                            started_at,
                            snapshot_completed_at=bson_ts_to_iso(snapshot_time),
                            last_event_timestamp=last_event_ts,
                            last_resume_token=last_token,
                            status="running",
                        )

    except KeyboardInterrupt:
        print("\nListener stopped.")

    finally:
        write_metadata(
            pipeline_id,
            started_at,
            snapshot_completed_at=bson_ts_to_iso(snapshot_time),
            last_event_timestamp=last_event_ts,
            last_resume_token=last_token,
            status="stopped",
        )


if __name__ == "__main__":
    main()
