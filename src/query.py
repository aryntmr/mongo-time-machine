import argparse
from datetime import datetime, timezone

from google.cloud import bigquery

import config

bq_client = bigquery.Client(project=config.GCP_PROJECT_ID)
TABLE = f"`{config.GCP_PROJECT_ID}.{config.BQ_DATASET}.{config.BQ_TABLE}`"
META  = f"`{config.GCP_PROJECT_ID}.{config.BQ_DATASET}.{config.BQ_METADATA_TABLE}`"


def check_data_coverage(target_time: datetime) -> None:
    """Warn if target_time predates the earliest data we have captured.

    Queries pipeline_metadata for the most recent completed snapshot time.
    If the requested timestamp falls before that, the result may be incomplete
    (prices that existed before the pipeline started are not in BigQuery).
    """
    sql = f"""
        SELECT snapshot_completed_at, status
        FROM {META}
        WHERE snapshot_completed_at IS NOT NULL
        ORDER BY snapshot_completed_at ASC
        LIMIT 1
    """
    rows = list(bq_client.query(sql).result())
    if not rows:
        print("WARNING: No pipeline metadata found. Has the listener run yet?")
        return
    snap_time = rows[0]["snapshot_completed_at"]
    if snap_time and target_time < snap_time:
        print(
            f"WARNING: Requested time {target_time.strftime('%Y-%m-%d %H:%M:%S UTC')} "
            f"is before earliest data ({snap_time.strftime('%Y-%m-%d %H:%M:%S UTC')}). "
            f"Result may be incomplete."
        )


def point_in_time(name: str, target_time: datetime) -> None:
    check_data_coverage(target_time)
    sql = f"""
        SELECT price, timestamp
        FROM {TABLE}
        WHERE name = @name
          AND timestamp <= @target_time
        ORDER BY timestamp DESC
        LIMIT 1
    """
    job_config = bigquery.QueryJobConfig(
        query_parameters=[
            bigquery.ScalarQueryParameter("name", "STRING", name),
            bigquery.ScalarQueryParameter("target_time", "TIMESTAMP", target_time),
        ]
    )
    rows = list(bq_client.query(sql, job_config=job_config).result())
    if not rows:
        print(f"No data found for {name} at or before {target_time.strftime('%Y-%m-%d %H:%M:%S UTC')}")
        return
    row = rows[0]
    print(f"{name}  price={row.price:.2f}  as of {row.timestamp.strftime('%Y-%m-%d %H:%M:%S UTC')}")


def latest(name: str) -> None:
    sql = f"""
        SELECT price, timestamp
        FROM {TABLE}
        WHERE name = @name
        ORDER BY timestamp DESC
        LIMIT 1
    """
    job_config = bigquery.QueryJobConfig(
        query_parameters=[
            bigquery.ScalarQueryParameter("name", "STRING", name),
        ]
    )
    rows = list(bq_client.query(sql, job_config=job_config).result())
    if not rows:
        print(f"No data found for {name}")
        return
    row = rows[0]
    print(f"{name}  price={row.price:.2f}  as of {row.timestamp.strftime('%Y-%m-%d %H:%M:%S UTC')}")


def all_at_time(target_time: datetime) -> None:
    check_data_coverage(target_time)
    sql = f"""
        SELECT name, price, timestamp
        FROM {TABLE}
        WHERE timestamp <= @target_time
        QUALIFY ROW_NUMBER() OVER (PARTITION BY name ORDER BY timestamp DESC) = 1
        ORDER BY name
    """
    job_config = bigquery.QueryJobConfig(
        query_parameters=[
            bigquery.ScalarQueryParameter("target_time", "TIMESTAMP", target_time),
        ]
    )
    rows = list(bq_client.query(sql, job_config=job_config).result())
    if not rows:
        print(f"No data found at or before {target_time.strftime('%Y-%m-%d %H:%M:%S UTC')}")
        return
    for row in rows:
        print(f"{row.name:<6}  price={row.price:.2f}  as of {row.timestamp.strftime('%Y-%m-%d %H:%M:%S UTC')}")


def parse_time(s: str) -> datetime:
    for fmt in ("%Y-%m-%d %H:%M:%S", "%Y-%m-%dT%H:%M:%S", "%Y-%m-%d"):
        try:
            return datetime.strptime(s, fmt).replace(tzinfo=timezone.utc)
        except ValueError:
            pass
    raise argparse.ArgumentTypeError(f"Cannot parse time: {s!r}. Use 'YYYY-MM-DD HH:MM:SS'")


def main() -> None:
    parser = argparse.ArgumentParser(description="Point-in-time stock price query")
    parser.add_argument("--name", help="Stock name (e.g. AAPL)")
    parser.add_argument("--time", type=parse_time, metavar="TIMESTAMP",
                        help="Target time in UTC: 'YYYY-MM-DD HH:MM:SS'")
    parser.add_argument("--latest", action="store_true", help="Return most recent price for --name")
    parser.add_argument("--all-at-time", type=parse_time, metavar="TIMESTAMP", dest="all_at_time",
                        help="Return price of every stock at this time")
    args = parser.parse_args()

    if args.all_at_time:
        all_at_time(args.all_at_time)
    elif args.latest:
        if not args.name:
            parser.error("--latest requires --name")
        latest(args.name)
    elif args.time:
        if not args.name:
            parser.error("--time requires --name")
        point_in_time(args.name, args.time)
    else:
        parser.print_help()


if __name__ == "__main__":
    main()
