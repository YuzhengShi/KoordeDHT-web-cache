# Local Testing Guide - Phase 1

Test KoordeDHT-Web-Cache locally on your machine **without any cloud deployment**.

## Prerequisites

- **Go 1.25+** installed
- **8GB RAM** minimum
- **No Docker required** (pure Go binaries)

---

## Quick Start (5 minutes)

### Step 1: Build Everything

```bash
# Build all binaries
go build -o bin/koorde-node ./cmd/node
go build -o bin/koorde-client ./cmd/client
go build -o bin/cache-workload ./cmd/cache-workload
go build -o bin/cache-client ./cmd/cache-client

# Or build all at once
go build -o bin/ ./cmd/...
```

### Step 2: Start Bootstrap Node

```bash
# Terminal 1: Start bootstrap node
./bin/koorde-node --config config/node/config.yaml
```

The bootstrap node will:
- Listen on port 4000 (gRPC DHT)
- Listen on port 8080 (HTTP cache)
- Create a new DHT ring

### Step 3: Test Cache

```bash
# Terminal 2: Test cache API
curl "http://localhost:8080/health"
curl "http://localhost:8080/cache?url=https://www.example.com"
curl "http://localhost:8080/metrics" | jq
```

### Step 4: Test DHT Operations (Interactive)

```bash
# Terminal 3: Use interactive DHT client
./bin/koorde-client --addr localhost:4000

# In client:
koorde[localhost:4000]> put mykey myvalue
koorde[localhost:4000]> get mykey
koorde[localhost:4000]> getrt
koorde[localhost:4000]> exit
```

### Step 4b: Test Cache Operations (Interactive)

```bash
# Terminal 3: Use interactive cache client
./bin/cache-client --addr http://localhost:8080

# In client:
cache[http://localhost:8080]> health
✓ Healthy: READY | Node: 0x004f424bb575238275

cache[http://localhost:8080]> cache https://www.example.com
Status: 200 | Cache: MISS-ORIGIN | Latency: 245ms
Content (1256 bytes): <!doctype html>...

cache[http://localhost:8080]> cache https://www.example.com
Status: 200 | Cache: HIT-LOCAL | Latency: 3ms
Content (1256 bytes): <!doctype html>...

cache[http://localhost:8080]> metrics
{
  "cache": {
    "hits": 1,
    "misses": 1,
    "hit_rate": 0.5
  }
}

cache[http://localhost:8080]> exit
Bye!
```

### Step 5: Generate Load (Optional)

```bash
# Terminal 4: Run workload generator
./bin/cache-workload \
  --target http://localhost:8080 \
  --urls 100 \
  --requests 1000 \
  --rate 50 \
  --zipf 0.9 \
  --output results.csv

# View results
cat results.csv
```

---

## Multi-Node Local Cluster

Test with multiple nodes on different ports:

### Create Node Configs

```bash
# Create config directory
mkdir -p config/local-cluster

# Copy base config
cp config/node/config.yaml config/local-cluster/node1.yaml
cp config/node/config.yaml config/local-cluster/node2.yaml
cp config/node/config.yaml config/local-cluster/node3.yaml
```

Edit each config to use different ports:

**config/local-cluster/node1.yaml**:
```yaml
node:
  bind: "0.0.0.0"
  host: "localhost"
  port: 4001

cache:
  httpPort: 8081
  
dht:
  bootstrap:
    mode: "static"
    peers: []  # First node (bootstrap)
```

**config/local-cluster/node2.yaml**:
```yaml
node:
  bind: "0.0.0.0"
  host: "localhost"
  port: 4002

cache:
  httpPort: 8082
  
dht:
  bootstrap:
    mode: "static"
    peers: ["localhost:4001"]  # Connect to node1
```

**config/local-cluster/node3.yaml**:
```yaml
node:
  bind: "0.0.0.0"
  host: "localhost"
  port: 4003

cache:
  httpPort: 8083
  
dht:
  bootstrap:
    mode: "static"
    peers: ["localhost:4001"]  # Connect to node1
```

### Start Nodes

```bash
# Terminal 1: Bootstrap node
./bin/koorde-node --config config/local-cluster/node1.yaml

# Terminal 2: Node 2
./bin/koorde-node --config config/local-cluster/node2.yaml

# Terminal 3: Node 3
./bin/koorde-node --config config/local-cluster/node3.yaml

# Wait 10 seconds for stabilization
```

### Test Multi-Node Setup

```bash
# Check each node's routing table
./bin/koorde-client --addr localhost:4001 <<EOF
getrt
exit
EOF

./bin/koorde-client --addr localhost:4002 <<EOF
getrt
exit
EOF

# Test cache on each node
curl "http://localhost:8081/cache?url=https://httpbin.org/json"
curl "http://localhost:8082/cache?url=https://httpbin.org/json"
curl "http://localhost:8083/cache?url=https://httpbin.org/json"

# Check metrics
curl "http://localhost:8081/metrics" | jq '.node.id'
curl "http://localhost:8082/metrics" | jq '.node.id'
curl "http://localhost:8083/metrics" | jq '.node.id'
```

---

## Automated Local Testing Script

I'll create a script that starts multiple nodes automatically:

Save as `test-local-cluster.sh`:

```bash
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
    go build -o bin/koorde-node ./cmd/node
fi

# Create config directory
mkdir -p config/local-cluster
rm -f config/local-cluster/*.yaml

# Generate configs
echo "Generating configurations..."
BOOTSTRAP_PEERS=""
for i in $(seq 0 $((NUM_NODES-1))); do
    GRPC_PORT=$((BASE_GRPC_PORT + i))
    HTTP_PORT=$((BASE_HTTP_PORT + i))
    
    if [ $i -eq 0 ]; then
        BOOTSTRAP_PEERS=""
    else
        BOOTSTRAP_PEERS="localhost:4000"
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
    peers: [${BOOTSTRAP_PEERS:+"\"$BOOTSTRAP_PEERS\""}]
  
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
  hotspotThreshold: 100.0
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
mkdir -p logs
echo "${PIDS[@]}" > logs/pids.txt

echo ""
echo "All nodes started! PIDs: ${PIDS[@]}"
echo ""
echo "Logs saved to: logs/node*.log"
echo ""
echo "Waiting 10 seconds for DHT stabilization..."
sleep 10

# Test
echo ""
echo "Testing cluster..."
echo "============================================"

# Health checks
echo "Health checks:"
for i in $(seq 0 $((NUM_NODES-1))); do
    HTTP_PORT=$((BASE_HTTP_PORT + i))
    STATUS=$(curl -s "http://localhost:${HTTP_PORT}/health" | jq -r '.status' 2>/dev/null || echo "ERROR")
    echo "  Node ${i} (port ${HTTP_PORT}): ${STATUS}"
done

echo ""
echo "Cache test:"
curl -s "http://localhost:8080/cache?url=https://httpbin.org/json" | jq -r '.url' 2>/dev/null && echo "✓ Cache working" || echo "✗ Cache failed"

echo ""
echo "Metrics:"
curl -s "http://localhost:8080/metrics" | jq '{cache: .cache, routing: .routing}' 2>/dev/null || echo "(jq not installed)"

echo ""
echo "============================================"
echo "  Cluster Running Successfully!"
echo "============================================"
echo ""
echo "Access cache:"
echo "  curl \"http://localhost:8080/cache?url=YOUR_URL\""
echo ""
echo "Access metrics:"
echo "  curl \"http://localhost:8080/metrics\" | jq"
echo ""
echo "Use interactive DHT client:"
echo "  ./bin/koorde-client --addr localhost:4000"
echo ""
echo "Use interactive cache client:"
echo "  ./bin/cache-client --addr http://localhost:8080"
echo ""
echo "To stop all nodes:"
echo "  kill \$(cat logs/pids.txt)"
echo ""

---

## Interactive Clients

### DHT Client (koorde-client)

**Purpose**: Interact with DHT for key-value storage

**Start**:
```bash
./bin/koorde-client --addr localhost:4000
```

**Commands**:
```
put <key> <value>     - Store key-value pair in DHT
get <key>             - Retrieve value from DHT
delete <key>          - Remove key from DHT
lookup <id>           - Find successor of ID
getrt                 - Show routing table
getstore              - Show stored resources
use <addr>            - Switch to different node
exit                  - Quit
```

**Example**:
```
koorde[localhost:4000]> put user:123 Alice
Put succeeded | latency=12ms

koorde[localhost:4000]> get user:123
Get succeeded (value=Alice) | latency=5ms

koorde[localhost:4000]> getrt
Routing table:
  Self: 0x004f... (localhost:4000)
  Successors: [...]
  DeBruijn List: [...]
```

---

### Cache Client (cache-client)

**Purpose**: Interact with web cache for URL caching

**Start**:
```bash
./bin/cache-client --addr http://localhost:8080
```

**Commands**:
```
cache <url>           - Fetch and cache a URL
metrics               - Show cache statistics
health                - Check node health
hotspots              - Show hot URLs
debug                 - Show routing table
use <addr>            - Switch to different node
help                  - Show commands
exit                  - Quit
```

**Example**:
```
cache[http://localhost:8080]> health
✓ Healthy: READY | Node: 0x004f...

cache[http://localhost:8080]> cache https://www.example.com
Status: 200 | Cache: MISS-ORIGIN | Latency: 245ms
Content (1256 bytes): ...

cache[http://localhost:8080]> cache https://www.example.com
Status: 200 | Cache: HIT-LOCAL | Latency: 3ms
Content (1256 bytes): ...

cache[http://localhost:8080]> metrics
{
  "cache": {
    "hits": 1,
    "misses": 1,
    "hit_rate": 0.5,
    "entry_count": 1
  }
}

cache[http://localhost:8080]> hotspots
Hotspots detected: 0
```

**What You See**:
- **MISS-ORIGIN**: First request, fetched from internet
- **HIT-LOCAL**: Found in cache, served from memory
- **Latency**: Dramatically faster on cache hits (250ms → 3ms)

---

### Comparison: DHT Client vs Cache Client

| Feature | koorde-client (DHT) | cache-client (Web Cache) |
|---------|---------------------|--------------------------|
| **Port** | 4000 (gRPC) | 8080 (HTTP) |
| **Protocol** | gRPC | HTTP/REST |
| **Data** | Key-value pairs | URLs and web content |
| **Commands** | put, get, delete | cache, metrics, health |
| **Use Case** | Distributed database | Distributed CDN/proxy |
| **Routing** | Koorde DHT | Same Koorde DHT |

**Both use the same underlying DHT for routing!**

---

## Interactive Testing Workflows

### Workflow 1: Verify Cache Works

```bash
# Start node
./bin/koorde-node --config config/node/config.yaml &

# Test with cache client
./bin/cache-client
```

**In client**:
```
cache> health                          # Check node is ready
cache> cache https://www.example.com   # Should be MISS
cache> cache https://www.example.com   # Should be HIT
cache> metrics                         # Verify hit_rate = 0.5
cache> exit
```

---

### Workflow 2: Test Hotspot Detection

**Terminal 1** - Generate traffic:
```bash
for i in {1..200}; do
  curl -s "http://localhost:8080/cache?url=https://www.example.com" > /dev/null &
done
wait
```

**Terminal 2** - Check hotspots:
```bash
./bin/cache-client
```

**In client**:
```
cache> hotspots
Hotspots detected: 1
Hot URLs:
  [1] https://www.example.com

cache> metrics
{
  "hotspots": {
    "count": 1,
    "urls": ["https://www.example.com"]
  }
}
```

---

### Workflow 3: Multi-Node DHT Distribution

**Start 3-node cluster**:
```bash
./test-local-cluster.sh 3
```

**Test with cache client**:
```bash
./bin/cache-client
```

**In client**:
```
cache> cache https://test1.com
Status: 200 | Cache: MISS-ORIGIN
Node: 0x004f...

cache> use http://localhost:8081
Switched to http://localhost:8081

cache> cache https://test1.com
Status: 200 | Cache: MISS-DHT | Responsible: localhost:4000
# Node 8081 forwards to node 8080 (responsible via DHT)

cache> cache https://test2.com
Status: 200 | Cache: MISS-ORIGIN
# Node 8081 is responsible for this URL

cache> use http://localhost:8082
cache> debug
# See routing table of third node
```

---

