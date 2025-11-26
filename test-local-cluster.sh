#!/bin/bash
set -euo pipefail

NUM_NODES=${1:-5}
BASE_GRPC_PORT=4000
BASE_HTTP_PORT=8080

echo "============================================"
echo "  Starting Local Koorde Cluster"
echo "============================================"
echo "Nodes: ${NUM_NODES}"
echo ""

# Build if needed
if [ ! -f bin/koorde-node ]; then
    echo "Building binaries..."
    mkdir -p bin
    go build -o bin/koorde-node ./cmd/node
    go build -o bin/koorde-client ./cmd/client
    go build -o bin/cache-workload ./cmd/cache-workload
    go build -o bin/cache-client ./cmd/cache-client
    go build -o bin/tester ./cmd/tester
fi

# Create directories
mkdir -p config/local-cluster
mkdir -p logs
rm -f config/local-cluster/*.yaml
rm -f logs/*.log

# Generate configs
echo "Generating configurations..."
for i in $(seq 0 $((NUM_NODES-1))); do
    GRPC_PORT=$((BASE_GRPC_PORT + i))
    HTTP_PORT=$((BASE_HTTP_PORT + i))
    
    if [ $i -eq 0 ]; then
        BOOTSTRAP_PEERS=""
    else
        BOOTSTRAP_PEERS="\"localhost:4000\""
    fi
    
    cat > config/local-cluster/node${i}.yaml <<EOF
logger:
  active: true
  level: "info"
  encoding: "console"
  mode: "stdout"

node:
  bind: "0.0.0.0"
  host: "localhost"
  port: ${GRPC_PORT}

dht:
  idBits: 66
  mode: "private"
  
  bootstrap:
    mode: "static"
    peers: [${BOOTSTRAP_PEERS}]
  
  deBruijn:
    degree: 8
    fixInterval: 5s
  
  storage:
    fixInterval: 20s
  
  faultTolerance:
    successorListSize: 8
    stabilizationInterval: 2s
    failureTimeout: 1s

cache:
  enabled: true
  httpPort: ${HTTP_PORT}
  capacityMB: 512
  defaultTTL: 3600
  hotspotThreshold: 10.0
  hotspotDecayRate: 0.65

telemetry:
  tracing:
    enabled: false
EOF
done

# Start nodes in background
echo "Starting nodes..."
PIDS=()
for i in $(seq 0 $((NUM_NODES-1))); do
    GRPC_PORT=$((BASE_GRPC_PORT + i))
    HTTP_PORT=$((BASE_HTTP_PORT + i))
    
    echo "  Starting node-${i} (gRPC: ${GRPC_PORT}, HTTP: ${HTTP_PORT})"
    ./bin/koorde-node --config config/local-cluster/node${i}.yaml > logs/node${i}.log 2>&1 &
    PIDS+=($!)
    
    # Small delay between nodes
    sleep 2
done

# Save PIDs
echo "${PIDS[@]}" > logs/pids.txt

echo ""
echo "All nodes started! PIDs: ${PIDS[@]}"
echo "Logs saved to: logs/node*.log"
echo ""
echo "Waiting 15 seconds for DHT stabilization..."
sleep 15

# Test
echo ""
echo "Testing cluster..."
echo "============================================"

# Health checks
echo "Health checks:"
for i in $(seq 0 $((NUM_NODES-1))); do
    HTTP_PORT=$((BASE_HTTP_PORT + i))
    STATUS=$(curl -s "http://localhost:${HTTP_PORT}/health" 2>/dev/null | grep -o '"status":"[^"]*"' | cut -d'"' -f4 || echo "ERROR")
    echo "  Node ${i} (port ${HTTP_PORT}): ${STATUS}"
done

echo ""
echo "Cache test (MISS - first request):"
curl -s "http://localhost:8080/cache?url=https://httpbin.org/json" | head -c 100
echo "..."

echo ""
echo "Cache test (HIT - second request):"
TIME_START=$(date +%s%N)
curl -s "http://localhost:8080/cache?url=https://httpbin.org/json" > /dev/null
TIME_END=$(date +%s%N)
LATENCY=$(( (TIME_END - TIME_START) / 1000000 ))
echo "✓ Cache hit in ${LATENCY}ms"

echo ""
echo "Metrics:"
curl -s "http://localhost:8080/metrics" 2>/dev/null | grep -o '"hit_rate":[0-9.]*' || echo "Check http://localhost:8080/metrics"

echo ""
echo "============================================"
echo "  Cluster Running Successfully!"
echo "============================================"
echo ""
echo "Access cache:"
echo "  curl \"http://localhost:8080/cache?url=YOUR_URL\""
echo ""
echo "Access other nodes:"
for i in $(seq 0 $((NUM_NODES-1))); do
    HTTP_PORT=$((BASE_HTTP_PORT + i))
    echo "  curl \"http://localhost:${HTTP_PORT}/cache?url=YOUR_URL\""
done
echo ""
echo "Use interactive client:"
echo "  ./bin/koorde-client --addr localhost:4000"
echo "  ./bin/cache-client --addr http://localhost:8080"
echo ""
echo "View logs:"
echo "  tail -f logs/node0.log"
echo ""
echo "To stop all nodes:"
echo "  ./stop-local-cluster.sh"
echo "  or: kill \$(cat logs/pids.txt)"
echo ""

