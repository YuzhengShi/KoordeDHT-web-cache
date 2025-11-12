#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Koorde Web Cache Integration Test"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Cleanup
echo "[1/7] Cleaning up previous deployment..."
docker-compose down -v 2>/dev/null || true

# Start cluster
echo "[2/7] Starting cluster (1 bootstrap + 5 nodes)..."
docker-compose up -d --scale node=5

# Wait for stabilization
echo "[3/7] Waiting 60s for DHT stabilization..."
sleep 60

# Test 1: Health check
echo ""
echo "[4/7] Checking cluster health..."
echo "Bootstrap node:"
curl -s http://localhost:8080/health | jq '.'

echo ""
echo "Node status via gRPC client:"
docker exec koorde-client /usr/local/bin/koorde-client --addr=bootstrap:4000 getrt || true

# Test 2: Cache MISS
echo ""
echo "[5/7] Test: Cache MISS (first request)..."
echo "Requesting https://httpbin.org/json..."
RESPONSE=$(curl -s -w "\n---\nHTTP: %{http_code}\nTime: %{time_total}s\n" \
  -H "X-Test: Miss" \
  "http://localhost:8080/cache?url=https://httpbin.org/json")

echo "$RESPONSE" | head -30
echo ""
echo "Check X-Cache header:"
curl -s -I "http://localhost:8080/cache?url=https://httpbin.org/json" | grep "X-Cache" || echo "No X-Cache header"

# Test 3: Cache HIT
echo ""
echo "[6/7] Test: Cache HIT (second request, should be fast)..."
RESPONSE=$(curl -s -w "\n---\nHTTP: %{http_code}\nTime: %{time_total}s\n" \
  "http://localhost:8080/cache?url=https://httpbin.org/json")

echo "$RESPONSE" | head -30

# Test 4: Metrics
echo ""
echo "[7/7] Cache metrics:"
curl -s "http://localhost:8080/metrics" | jq '{
  node: .node.id,
  cache: {
    hit_rate: .cache.hit_rate,
    hits: .cache.hits,
    misses: .cache.misses,
    entries: .cache.entries
  },
  hotspots: .hotspots.count,
  routing: .routing
}'

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Test Complete!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Next steps:"
echo "  • View logs: docker-compose logs -f node"
echo "  • View Jaeger: http://localhost:16686"
echo "  • Interactive client: docker exec -it koorde-client /usr/local/bin/koorde-client --addr=bootstrap:4000"
echo "  • Cleanup: docker-compose down -v"