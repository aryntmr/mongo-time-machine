"""query.py -- Point-in-time stock price queries against BigQuery.

V4 additions:
- All price_history reads go through a deduplication CTE that keeps only
  the first-ingested row per event_id. This handles two sources of duplicates:
    1. Snapshot/change-stream overlap: listener captures cluster time, reads all
       docs, then opens the change stream at startAtOperationTime. Any write
       that happened in the same second appears in both snapshot and stream rows.
    2. Pub/Sub at-least-once redelivery: if the subscriber crashes after writing
       to BigQuery but before acking, messages are redelivered and written again.

Deduplication strategy — query-time (not write-time):
  The alternative (write-time dedup) would check whether an event_id already
  exists in BigQuery before inserting. This is unreliable because BigQuery
  streaming inserts have up to a 30-second buffer delay — a freshly written row
  won't appear in queries immediately, so the "does it exist?" check can miss it
  and produce duplicates anyway. An in-memory set in the subscriber handles hot
  duplicates within one process lifetime but is lost on restart.

  Query-time dedup via ROW_NUMBER() is idempotent, stateless, and handles all
  sources of duplication uniformly. On a clean table (no real duplicates) every
  row has rn=1 and the filter costs nothing extra.
"""

import argparse
import time
from datetime import datetime, timezone

from google.cloud import bigquery

import config

bq_client = bigquery.Client(project=config.GCP_PROJECT_ID)
TABLE = f"`{config.GCP_PROJECT_ID}.{config.BQ_DATASET}.{config.BQ_TABLE}`"
META  = f"`{config.GCP_PROJECT_ID}.{config.BQ_DATASET}.{config.BQ_METADATA_TABLE}`"


def fmt_timestamp(ts: datetime) -> str:
    """Format a BigQuery timestamp for display. Shows .NNN only if sub-second."""
    if ts.microsecond:
        return ts.strftime("%Y-%m-%d %H:%M:%S") + f".{ts.microsecond // 1000:03d} UTC"
    return ts.strftime("%Y-%m-%d %H:%M:%S UTC")


def bq_query_with_retry(sql: str, job_config=None, max_attempts: int = 5) -> list:
    """Run a BigQuery query, retrying on transient failures with exponential backoff.

    Raises the last exception if all attempts fail.
    """
    for attempt in range(max_attempts):
        try:
            return list(bq_client.query(sql, job_config=job_config).result())
        except Exception as e:
            if attempt == max_attempts - 1:
                raise
            wait = 2 ** attempt
            print(f"[BQ RETRY] Attempt {attempt + 1}/{max_attempts} failed: {e}. Retrying in {wait}s ...")
            time.sleep(wait)


def check_data_coverage(target_time: datetime) -> datetime | None:
    """Warn if target_time predates the earliest snapshot, and return that snapshot time.

    Returns the earliest snapshot_completed_at datetime (UTC-aware), or None if
    no metadata is available yet.
    """
    sql = f"""
        SELECT snapshot_completed_at
        FROM {META}
        WHERE snapshot_completed_at IS NOT NULL
        ORDER BY snapshot_completed_at ASC
        LIMIT 1
    """
    rows = bq_query_with_retry(sql)
    if not rows:
        print("WARNING: No pipeline metadata found. Has the listener run yet?")
        return None
    snap_time = rows[0]["snapshot_completed_at"]
    if snap_time and target_time < snap_time:
        print(
            f"WARNING: Requested time {fmt_timestamp(target_time)} "
            f"is before earliest data ({fmt_timestamp(snap_time)}). "
            f"Result may be incomplete."
        )
    return snap_time


def point_in_time(name: str, target_time: datetime) -> None:
    snap_time = check_data_coverage(target_time)

    # Dedup CTE: keep one row per event_id (first ingested wins), then find
    # the most recent price for this stock at or before the target time.
    sql = f"""
        WITH deduped AS (
            SELECT * EXCEPT (rn)
            FROM (
                SELECT *,
                       ROW_NUMBER() OVER (
                           PARTITION BY event_id
                           ORDER BY ingested_at ASC
                       ) AS rn
                FROM {TABLE}
                WHERE name = @name
            )
            WHERE rn = 1
        )
        SELECT price, timestamp
        FROM deduped
        WHERE timestamp <= @target_time
        ORDER BY timestamp DESC
        LIMIT 1
    """
    job_config = bigquery.QueryJobConfig(
        query_parameters=[
            bigquery.ScalarQueryParameter("name", "STRING", name),
            bigquery.ScalarQueryParameter("target_time", "TIMESTAMP", target_time),
        ]
    )
    rows = bq_query_with_retry(sql, job_config)
    if not rows:
        if snap_time and target_time < snap_time:
            print(
                f"No data available for {name} before "
                f"{fmt_timestamp(snap_time)}. "
                f"Pipeline data starts at {fmt_timestamp(snap_time)}."
            )
        else:
            print(f"Stock '{name}' not found.")
        return
    row = rows[0]
    print(f"{name}  price={row.price:.2f}  as of {fmt_timestamp(row.timestamp)}")


def latest(name: str) -> None:
    sql = f"""
        WITH deduped AS (
            SELECT * EXCEPT (rn)
            FROM (
                SELECT *,
                       ROW_NUMBER() OVER (
                           PARTITION BY event_id
                           ORDER BY ingested_at ASC
                       ) AS rn
                FROM {TABLE}
                WHERE name = @name
            )
            WHERE rn = 1
        )
        SELECT price, timestamp
        FROM deduped
        ORDER BY timestamp DESC
        LIMIT 1
    """
    job_config = bigquery.QueryJobConfig(
        query_parameters=[
            bigquery.ScalarQueryParameter("name", "STRING", name),
        ]
    )
    rows = bq_query_with_retry(sql, job_config)
    if not rows:
        print(f"Stock '{name}' not found.")
        return
    row = rows[0]
    print(f"{name}  price={row.price:.2f}  as of {fmt_timestamp(row.timestamp)}")


def all_at_time(target_time: datetime) -> None:
    check_data_coverage(target_time)

    # Two-level windowing:
    #   Inner CTE (deduped): collapse duplicate event_ids, keeping first ingested.
    #   QUALIFY clause: for each stock name, keep only the most recent price
    #                   at or before target_time.
    sql = f"""
        WITH deduped AS (
            SELECT * EXCEPT (rn)
            FROM (
                SELECT *,
                       ROW_NUMBER() OVER (
                           PARTITION BY event_id
                           ORDER BY ingested_at ASC
                       ) AS rn
                FROM {TABLE}
                WHERE timestamp <= @target_time
            )
            WHERE rn = 1
        )
        SELECT name, price, timestamp
        FROM deduped
        QUALIFY ROW_NUMBER() OVER (PARTITION BY name ORDER BY timestamp DESC) = 1
        ORDER BY name
    """
    job_config = bigquery.QueryJobConfig(
        query_parameters=[
            bigquery.ScalarQueryParameter("target_time", "TIMESTAMP", target_time),
        ]
    )
    rows = bq_query_with_retry(sql, job_config)
    if not rows:
        print(f"No stocks found at or before {fmt_timestamp(target_time)}.")
        return
    for row in rows:
        print(f"{row.name:<6}  price={row.price:.2f}  as of {fmt_timestamp(row.timestamp)}")


def parse_time(s: str) -> datetime:
    for fmt in (
        "%Y-%m-%d %H:%M:%S.%f",
        "%Y-%m-%d %H:%M:%S",
        "%Y-%m-%dT%H:%M:%S.%f",
        "%Y-%m-%dT%H:%M:%S",
        "%Y-%m-%d",
    ):
        try:
            return datetime.strptime(s, fmt).replace(tzinfo=timezone.utc)
        except ValueError:
            pass
    raise argparse.ArgumentTypeError(f"Cannot parse time: {s!r}. Use 'YYYY-MM-DD HH:MM:SS[.fff]'")


def main() -> None:
    parser = argparse.ArgumentParser(description="Point-in-time stock price query")
    parser.add_argument("--name", help="Stock name (e.g. AAPL)")
    parser.add_argument("--time", type=parse_time, metavar="TIMESTAMP",
                        help="Target time in UTC: 'YYYY-MM-DD HH:MM:SS[.fff]'")
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
