import random
import time
from datetime import datetime, timezone

import config

client = config.get_mongo_client()
collection = client[config.DB_NAME][config.COLLECTION]

prices = {doc["name"]: doc["price"] for doc in collection.find()}

if not prices:
    print("No stocks found in collection. Is the replica set initialized? Run: make up")
    raise SystemExit(1)

print(f"Loaded {len(prices)} stocks: {list(prices.keys())}")

try:
    while True:
        stock = random.choice(list(prices.keys()))
        old_price = prices[stock]
        new_price = max(1.0, old_price + random.uniform(-2, 2))
        prices[stock] = new_price

        collection.update_one({"name": stock}, {"$set": {"price": new_price}})

        ts = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S.%f")[:-3]
        print(f"[{ts}] UPDATE  {stock:<5}  {old_price:.2f} → {new_price:.2f}")

        if config.BURSTY_MODE:
            time.sleep(random.uniform(config.BURSTY_MIN, config.BURSTY_MAX))
        else:
            time.sleep(config.UPDATE_INTERVAL)

except KeyboardInterrupt:
    print("\nSimulator stopped.")
