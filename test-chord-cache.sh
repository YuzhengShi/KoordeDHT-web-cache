#!/bin/bash
set -euo pipefail

echo "============================================"
echo "  Testing Chord Cache Operations"
echo "============================================"
echo ""

# Build if needed
if [ ! -f bin/node.exe ]; then
    echo "Building node binary..."
    mkdir -p bin
    go build -o bin/node.exe ./cmd/node
fi

# Create test configs
mkdir -p config/chord-test
rm -f config/chord-test/*.yaml

# Node 1 (Bootstrap)
cat > config/chord-test/node1.yaml <<EOF
logger:
  active: true
  level: info
  encoding: console
  mode: stdout

dht:
  idBits: 66
  protocol: chord
  mode: private
  bootstrap:
    mode: static
    peers: []
  deBruijn:
    degree: 2
    fixInterval: 5s
  faultTolerance:
    successorListSize: 8
    stabilizationInterval: 2s
    failureTimeout: 1s
  storage:
    fixInterval: 20s

node:
  id: ""
  bind: "0.0.0.0"
  host: "localhost"
  port: 4000

cache:
  enabled: true
  httpPort: 8080
  capacityMB: 512
  defaultTTL: 3600
  hotspotThreshold: 10.0
  hotspotDecayRate: 0.65

telemetry:
  tracing:
    enabled: false
EOF

# Node 2 (Join)
cat > config/chord-test/node2.yaml <<EOF
logger:
  active: true
  level: info
  encoding: console
  mode: stdout

dht:
  idBits: 66
  protocol: chord
  mode: private
  bootstrap:
    mode: static
    peers: ["localhost:4000"]
  deBruijn:
    degree: 2
    fixInterval: 5s
  faultTolerance:
    successorListSize: 8
    stabilizationInterval: 2s
    failureTimeout: 1s
  storage:
    fixInterval: 20s

node:
  id: ""
  bind: "0.0.0.0"
  host: "localhost"
  port: 4001

cache:
  enabled: true
  httpPort: 8081
  capacityMB: 512
  defaultTTL: 3600
  hotspotThreshold: 10.0
  hotspotDecayRate: 0.65

telemetry:
  tracing:
    enabled: false
EOF

# Node 3 (Join)
cat > config/chord-test/node3.yaml <<EOF
logger:
  active: true
  level: info
  encoding: console
  mode: stdout

dht:
  idBits: 66
  protocol: chord
  mode: private
  bootstrap:
    mode: static
    peers: ["localhost:4000"]
  deBruijn:
    degree: 2
    fixInterval: 5s
  faultTolerance:
    successorListSize: 8
    stabilizationInterval: 2s
    failureTimeout: 1s
  storage:
    fixInterval: 20s

node:
  id: ""
  bind: "0.0.0.0"
  host: "localhost"
  port: 4002

cache:
  enabled: true
  httpPort: 8082
  capacityMB: 512
  defaultTTL: 3600
  hotspotThreshold: 10.0
  hotspotDecayRate: 0.65

telemetry:
  tracing:
    enabled: false
EOF

echo "Starting Chord cluster..."
echo ""

# Start nodes in background
echo "Starting Node 1 (bootstrap)..."
./bin/node.exe -config config/chord-test/node1.yaml > logs/chord-node1.log 2>&1 &
NODE1_PID=$!
echo "Node 1 PID: $NODE1_PID"

sleep 3

echo "Starting Node 2..."
./bin/node.exe -config config/chord-test/node2.yaml > logs/chord-node2.log 2>&1 &
NODE2_PID=$!
echo "Node 2 PID: $NODE2_PID"

sleep 3

echo "Starting Node 3..."
./bin/node.exe -config/chord-test/node3.yaml > logs/chord-node3.log 2>&1 &
NODE3_PID=$!
echo "Node 3 PID: $NODE3_PID"

echo ""
echo "Waiting 10 seconds for cluster to stabilize..."
sleep 10

echo ""
echo "============================================"
echo "  Testing Cache Operations"
echo "============================================"
echo ""

# Test 1: Health check
echo "Test 1: Health Check"
echo "-------------------"
for port in 8080 8081 8082; do
    echo -n "Node on port $port: "
    if curl -s http://localhost:$port/health | grep -q "healthy"; then
        echo "✓ Healthy"
    else
        echo "✗ Unhealthy"
    fi
done
echo ""

# Test 2: Debug endpoint (check finger table)
echo "Test 2: Debug Endpoint (Finger Table)"
echo "-------------------------------------"
for port in 8080 8081 8082; do
    echo "Node on port $port:"
    curl -s http://localhost:$port/debug | jq -r '.routing | "  Successors: \(.successor_count), DeBruijn: \(.debruijn_count), Has Predecessor: \(.has_predecessor)"'
done
echo ""

# Test 3: Cache operations
echo "Test 3: Cache Operations"
echo "------------------------"
TEST_URL="https://httpbin.org/json"

echo "Requesting $TEST_URL from Node 1 (port 8080)..."
RESPONSE1=$(curl -s -w "\n%{http_code}\n%{header_x-cache}\n" "http://localhost:8080/cache?url=$TEST_URL")
HTTP_CODE1=$(echo "$RESPONSE1" | tail -n 2 | head -n 1)
CACHE_STATUS1=$(echo "$RESPONSE1" | tail -n 1)
echo "  HTTP Code: $HTTP_CODE1"
echo "  Cache Status: $CACHE_STATUS1"
echo ""

echo "Requesting same URL from Node 2 (port 8081)..."
RESPONSE2=$(curl -s -w "\n%{http_code}\n%{header_x-cache}\n" "http://localhost:8081/cache?url=$TEST_URL")
HTTP_CODE2=$(echo "$RESPONSE2" | tail -n 2 | head -n 1)
CACHE_STATUS2=$(echo "$RESPONSE2" | tail -n 1)
echo "  HTTP Code: $HTTP_CODE2"
echo "  Cache Status: $CACHE_STATUS2"
echo ""

echo "Requesting same URL again from Node 1 (should be cached)..."
RESPONSE3=$(curl -s -w "\n%{http_code}\n%{header_x-cache}\n" "http://localhost:8080/cache?url=$TEST_URL")
HTTP_CODE3=$(echo "$RESPONSE3" | tail -n 2 | head -n 1)
CACHE_STATUS3=$(echo "$RESPONSE3" | tail -n 1)
echo "  HTTP Code: $HTTP_CODE3"
echo "  Cache Status: $CACHE_STATUS3"
echo ""

# Test 4: Metrics
echo "Test 4: Cache Metrics"
echo "--------------------"
for port in 8080 8081 8082; do
    echo "Node on port $port:"
    curl -s http://localhost:$port/metrics | jq -r '.cache | "  Hits: \(.hits), Misses: \(.misses), Hit Rate: \(.hit_rate), Entries: \(.entry_count)"'
done
echo ""

# Test 5: Multiple URLs
echo "Test 5: Multiple URLs (Distribution Test)"
echo "--------------------------------------"
URLS=(
    "https://httpbin.org/json"
    "https://httpbin.org/uuid"
    "https://httpbin.org/base64/SFRUUEJJTiBpcyBhd2Vzb21l"
)

for url in "${URLS[@]}"; do
    echo "Requesting $url from Node 1..."
    RESPONSE=$(curl -s -w "\n%{header_x-node-id}\n%{header_x-cache}\n" "http://localhost:8080/cache?url=$url" | tail -n 2)
    NODE_ID=$(echo "$RESPONSE" | head -n 1)
    CACHE_STATUS=$(echo "$RESPONSE" | tail -n 1)
    echo "  Responsible Node: $NODE_ID"
    echo "  Cache Status: $CACHE_STATUS"
done
echo ""

echo "============================================"
echo "  Test Summary"
echo "============================================"
echo ""
echo "All tests completed. Check logs in logs/chord-node*.log for details."
echo ""
echo "To stop the cluster, run:"
echo "  kill $NODE1_PID $NODE2_PID $NODE3_PID"
echo ""
echo "Or use: pkill -f 'node.exe.*chord-test'"

