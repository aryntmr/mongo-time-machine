#!/bin/bash
set -e

echo "Waiting for mongo1 to be ready..."
until mongosh --host mongo1:27017 --eval "db.adminCommand('ping')" > /dev/null 2>&1; do
  sleep 1
done
echo "mongo1 is up."

echo "Initiating replica set with host.docker.internal addresses..."
mongosh --host mongo1:27017 --eval '
rs.initiate({
  _id: "rs0",
  members: [
    { _id: 0, host: "host.docker.internal:27017" },
    { _id: 1, host: "host.docker.internal:27018" },
    { _id: 2, host: "host.docker.internal:27019" }
  ]
})
'

echo "Waiting for PRIMARY election..."
until mongosh --host mongo1:27017 --eval "rs.status().members.some(m => m.stateStr === 'PRIMARY')" | grep -q "true"; do
  sleep 2
done
echo "PRIMARY elected."

echo "Seeding stock data..."
mongosh "mongodb://mongo1:27017,mongo2:27017,mongo3:27017/?replicaSet=rs0" --eval '
db = db.getSiblingDB("stockdb");
const stocks = [
  { name: "AAPL", price: 150 },
  { name: "GOOG", price: 140 },
  { name: "TSLA", price: 250 },
  { name: "AMZN", price: 185 },
  { name: "MSFT", price: 380 }
];
stocks.forEach(s => {
  db.stocks.updateOne({ name: s.name }, { $set: s }, { upsert: true });
});
print("Seeded " + stocks.length + " stocks.");
'

echo "Init complete."
