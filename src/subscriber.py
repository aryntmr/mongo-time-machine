"""subscriber.py -- Pub/Sub to BigQuery micro-batch writer.

Pulls price events from a Pub/Sub subscription and writes them to BigQuery
in micro-batches (up to 500 events or 2 seconds, whichever comes first).
Messages are acked only after a successful BigQuery write; nacked on failure
so Pub/Sub redelivers them.
"""

import json
import os
import signal
import threading
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

from google.cloud import bigquery, pubsub_v1

import config

# BigQuery
bq_client = bigquery.Client(project=config.GCP_PROJECT_ID)
table_ref = f"{config.GCP_PROJECT_ID}.{config.BQ_DATASET}.{config.BQ_TABLE}"

# Pub/Sub
subscriber = pubsub_v1.SubscriberClient()
subscription_path = subscriber.subscription_path(
    config.GCP_PROJECT_ID, config.PUBSUB_SUBSCRIPTION
)

# Batch config
BATCH_MAX_SIZE = 500
BATCH_MAX_WAIT = 2.0  # seconds

# Shared state
lock = threading.Lock()
batch: list[tuple] = []   # (message, row_dict) pairs
batch_start: float | None = None
shutdown = threading.Event()


def flush() -> None:
    """Write accumulated batch to BigQuery. Must be called with lock held.

    Releases the lock during the BigQuery write to avoid blocking callbacks,
    then re-acquires it to reset state. Messages are acked/nacked outside
    the lock since those are per-message RPC calls.
    """
    global batch, batch_start

    if not batch:
        return

    current_batch = batch
    batch = []
    batch_start = None

    # Release lock during I/O so callbacks can continue appending
    lock.release()
    try:
        rows = [row for _, row in current_batch]
        messages = [msg for msg, _ in current_batch]

        try:
            errors = bq_client.insert_rows_json(table_ref, rows)
        except Exception as e:
            # BigQuery threw (network error, auth error, etc.) — nack all
            print(f"[BQ EXCEPTION] {e}")
            for msg in messages:
                msg.nack()
            print(f"  Nacked {len(messages)} messages for redelivery")
            return

        if errors:
            print(f"[BQ ERROR] {errors}")
            for msg in messages:
                msg.nack()
            print(f"  Nacked {len(messages)} messages for redelivery")
        else:
            for msg in messages:
                msg.ack()
            print(f"[BQ OK] {len(rows)} rows written, {len(messages)} messages acked")
    finally:
        lock.acquire()


def callback(message) -> None:
    """Called by streaming pull for each message."""
    global batch_start

    try:
        row = json.loads(message.data.decode("utf-8"))
    except (json.JSONDecodeError, UnicodeDecodeError):
        print(f"[BAD MSG] Cannot decode, nacking: {message.message_id}")
        message.nack()
        return

    with lock:
        batch.append((message, row))
        if batch_start is None:
            batch_start = time.monotonic()
        if len(batch) >= BATCH_MAX_SIZE:
            flush()


def timer_loop() -> None:
    """Periodically flush batch based on time threshold."""
    while not shutdown.is_set():
        time.sleep(0.1)
        with lock:
            if batch and batch_start and (time.monotonic() - batch_start >= BATCH_MAX_WAIT):
                flush()


def _start_health_server() -> None:
    """Start a minimal HTTP server so Cloud Run health checks pass.

    Cloud Run requires every container to listen on PORT (default 8080).
    This runs in a daemon thread — it doesn't affect the Pub/Sub pull loop.
    """
    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"OK")
        def log_message(self, *args):
            pass  # suppress access logs

    port = int(os.environ.get("PORT", 8080))
    server = HTTPServer(("", port), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()


def main() -> None:
    _start_health_server()
    print(f"Subscriber starting ...")
    print(f"  Project      : {config.GCP_PROJECT_ID}")
    print(f"  Subscription : {config.PUBSUB_SUBSCRIPTION}")
    print(f"  Batch size   : {BATCH_MAX_SIZE}")
    print(f"  Batch timeout: {BATCH_MAX_WAIT}s")

    streaming_pull_future = subscriber.subscribe(
        subscription_path,
        callback=callback,
        flow_control=pubsub_v1.types.FlowControl(max_messages=1000),
    )

    print("Listening for messages ...")

    def signal_handler(sig, frame):
        print("\nShutdown requested ...")
        shutdown.set()
        streaming_pull_future.cancel()

    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)

    try:
        timer_loop()
    finally:
        with lock:
            flush()
        subscriber.close()
        print("Subscriber stopped.")


if __name__ == "__main__":
    main()
