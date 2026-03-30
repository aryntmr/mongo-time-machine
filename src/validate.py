"""validate.py — compare current MongoDB state against BigQuery history.

For each stock in MongoDB, looks up the latest price in BigQuery and compares.
Reports OK / MISSING / MISMATCH per stock. Exits with code 1 if any issue found.

Usage:
    python validate.py
"""
import sys

from google.cloud import bigquery

import config


def main() -> None:
    mongo_client = config.get_mongo_client()
    collection = mongo_client[config.DB_NAME][config.COLLECTION]
    bq_client = bigquery.Client(project=config.GCP_PROJECT_ID)

    # Current state from MongoDB
    mongo_docs = list(collection.find({}, {"name": 1, "price": 1, "_id": 0}))
    if not mongo_docs:
        print("No documents found in MongoDB.")
        sys.exit(0)
    mongo_prices = {doc["name"]: float(doc["price"]) for doc in mongo_docs}

    # Latest price per stock from BigQuery history
    table = f"`{config.GCP_PROJECT_ID}.{config.BQ_DATASET}.{config.BQ_TABLE}`"
    sql = f"""
        SELECT name, price
        FROM {table}
        QUALIFY ROW_NUMBER() OVER (PARTITION BY name ORDER BY timestamp DESC, ingested_at DESC) = 1
    """
    bq_rows = list(bq_client.query(sql).result())
    bq_prices = {row["name"]: float(row["price"]) for row in bq_rows}

    # Compare and report
    all_ok = True
    print(f"{'STOCK':<8}  {'STATUS':<10}  {'MONGO':>10}  {'BIGQUERY':>10}")
    print("-" * 46)

    for name in sorted(mongo_prices):
        mongo_price = mongo_prices[name]
        if name not in bq_prices:
            status = "MISSING"
            bq_str = "N/A"
            all_ok = False
        elif abs(mongo_price - bq_prices[name]) < 0.001:
            status = "OK"
            bq_str = f"{bq_prices[name]:.2f}"
        else:
            status = "MISMATCH"
            bq_str = f"{bq_prices[name]:.2f}"
            all_ok = False
        print(f"{name:<8}  {status:<10}  {mongo_price:>10.2f}  {bq_str:>10}")

    print()
    if all_ok:
        print("All stocks match. Pipeline is in sync.")
        sys.exit(0)
    else:
        print("Discrepancies found. Pipeline may have missed events.")
        sys.exit(1)


if __name__ == "__main__":
    main()
