from datetime import datetime, timezone

from bson import Timestamp

import config

client = config.get_mongo_client()
collection = client[config.DB_NAME][config.COLLECTION]


def bson_ts_to_datetime(ts: Timestamp) -> str:
    # ts.time is seconds-precision Unix time; ts.inc is an ordinal counter for
    # ordering events within the same second — not a fractional second.
    return datetime.fromtimestamp(ts.time, tz=timezone.utc).strftime("%Y-%m-%d %H:%M:%S") + f" (ord={ts.inc})"


print(f"Listening for changes on {config.DB_NAME}.{config.COLLECTION} ...")

try:
    with collection.watch(full_document="updateLookup") as stream:
        for event in stream:
            op = event.get("operationType", "unknown").upper()
            doc = event.get("fullDocument") or {}
            name = doc.get("name", "N/A")
            price = doc.get("price")
            cluster_time = event.get("clusterTime")
            token = event["_id"]["_data"]

            ts_str = bson_ts_to_datetime(cluster_time) if cluster_time else "N/A"
            price_str = f"{price:.2f}" if isinstance(price, (int, float)) else "N/A"
            print(f"[{ts_str}]  {op:<8}  name={name:<5}  price={price_str}  token={token}")

except KeyboardInterrupt:
    print("\nListener stopped.")
