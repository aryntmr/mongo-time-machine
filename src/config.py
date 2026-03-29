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

GCP_PROJECT_ID  = os.getenv("GCP_PROJECT_ID", "")
BQ_DATASET      = os.getenv("BQ_DATASET", "stock_history")
BQ_TABLE        = os.getenv("BQ_TABLE", "price_history")
# GOOGLE_APPLICATION_CREDENTIALS is read automatically by the BigQuery client


def get_mongo_client() -> pymongo.MongoClient:
    """Connect to MongoDB.

    Tries MONGO_URI first. If hostname resolution fails (common on macOS when
    host.docker.internal is not in /etc/hosts), falls back to scanning
    localhost:27017-27019 with directConnection to find the current PRIMARY.
    """
    # Quick hostname resolution check before attempting the full URI.
    # Avoids a multi-second timeout on macOS when host.docker.internal is absent.
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
