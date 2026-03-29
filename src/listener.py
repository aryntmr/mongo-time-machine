from datetime import datetime, timezone

from bson import Timestamp
from google.cloud import bigquery

import config

client = config.get_mongo_client()
collection = client[config.DB_NAME][config.COLLECTION]

bq_client = bigquery.Client(project=config.GCP_PROJECT_ID)
table_ref = f"{config.GCP_PROJECT_ID}.{config.BQ_DATASET}.{config.BQ_TABLE}"


def bson_ts_to_datetime(ts: Timestamp) -> str:
    # ts.time is seconds-precision Unix time; ts.inc is an ordinal counter for
    # ordering events within the same second — not a fractional second.
    return datetime.fromtimestamp(ts.time, tz=timezone.utc).strftime("%Y-%m-%d %H:%M:%S") + f" (ord={ts.inc})"


print(f"Listening for changes on {config.DB_NAME}.{config.COLLECTION} ...")

try:
    with collection.watch(full_document="updateLookup") as stream:
        for event in stream:
            op = event.get("operationType", "unknown")
            doc = event.get("fullDocument") or {}
            name = doc.get("name", "N/A")

            # Use atomic source for updates to avoid fullDocument race condition
            # (fullDocument is a snapshot taken after the event fires — a rapid
            # second update can contaminate it with a later value).
            if op == "update":
                updated_fields = event.get("updateDescription", {}).get("updatedFields", {})
                price = updated_fields.get("price", doc.get("price"))
            else:
                price = doc.get("price")

            cluster_time = event.get("clusterTime")
            token = event["_id"]["_data"]

            ts_str = bson_ts_to_datetime(cluster_time) if cluster_time else "N/A"
            price_str = f"{price:.2f}" if isinstance(price, (int, float)) else "N/A"
            print(f"[{ts_str}]  {op.upper():<8}  name={name:<5}  price={price_str}  token={token}")

            # Write to BigQuery
            if cluster_time and price is not None and name != "N/A":
                row = {
                    "name": name,
                    "price": float(price),
                    "timestamp": datetime.fromtimestamp(cluster_time.time, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                    "operation_type": op,
                    "event_id": token,
                    "ingested_at": datetime.now(tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ"),
                }
                errors = bq_client.insert_rows_json(table_ref, [row])
                if errors:
                    print(f"  [BQ ERROR] {errors}")
                else:
                    print(f"  [BQ OK]")

except KeyboardInterrupt:
    print("\nListener stopped.")
