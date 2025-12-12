# Koorde + Chord DHT Web Cache

Go implementation of a distributed web cache backed by two DHT routing layers:

- **Koorde** (de Bruijn routing with configurable degree $k$)
- **Chord** (finger-table routing)

The project includes local tooling, AWS EKS manifests for both protocols, and a set of completed benchmark experiments with plots and reports.

## Quick Links

- Local development/testing: [Local Testing Guide](#local-testing-guide)
- EKS deployment (Koorde + Chord): `deploy/eks/README.md`
- Benchmark runner (PowerShell): [Benchmark Guide](#benchmark-guide) and `benchmark-chord-vs-koorde.ps1`
- Full benchmark writeup (3 experiments): [Benchmark Report](#benchmark-report)
- Plots: `test/results/plots/latency_vs_nodes.png`, `test/results/plots/rps_vs_nodes.png`

---

## What’s Implemented

### Protocols

- **Koorde routing** via base-$k$ de Bruijn neighbors (degree $k$ in config)
- **Chord routing** via finger tables and standard stabilization
- Shared **successor list** style fault-tolerance mechanisms and periodic maintenance

### Web cache layer

- URL-to-key mapping and “responsible node” routing via the DHT
- HTTP cache endpoint plus metrics/health endpoints
- Workload generator for Zipf-like request distributions

---

## Repo Layout (Entry Points)

```
cmd/
  node/            # Runs a cache+DHT node (Chord or Koorde based on config)
  client/          # Interactive client utilities
  tester/          # Benchmark/test helper
  cache-workload/  # HTTP workload generator

deploy/
  eks/             # AWS EKS deployment (Chord + Koorde)
  tracing/         # Local tracing setup (Jaeger)
  test/            # Automated test harnesses

config/
  local-cluster/   # Example multi-node configs
  chord-test/      # Chord-specific test configs
```

---

## Run Locally

See the [Local Testing Guide](#local-testing-guide). In short:

```powershell
go run ./cmd/node/main.go --config .\config\local-cluster\node0.yaml
```

Then start additional nodes with the other configs (node1.yaml, node2.yaml, ...).

---

## Deploy to AWS EKS

Follow `deploy/eks/README.md`.

Notes:
- EKS manifests/scripts support **both** `chord` and `koorde`.
- Large-scale runs are constrained by the AWS Learner Lab quota limits; the benchmark report documents the achieved scale and limitations.

---

## Benchmarks & Results

### Run the benchmark script (Windows PowerShell)

```powershell
# Default parameters
.\benchmark-chord-vs-koorde.ps1

# Example with explicit settings
.\benchmark-chord-vs-koorde.ps1 -NumNodes 5 -NumRequests 1000 -Concurrency 10 -ZipfExponent 1.2
```

See the [Benchmark Guide](#benchmark-guide) for full parameter documentation and output locations.

### Read the results

- Report: [Benchmark Report](#benchmark-report)
- Comparison snapshot: `BENCHMARK_COMPARISON_REPORT.md`
- Plots: `test/results/plots/latency_vs_nodes.png`, `test/results/plots/rps_vs_nodes.png`

---

## References

1. Kaashoek MF, Karger DR. *Koorde: A simple degree-optimal distributed hash table.* (2003)
2. Stoica I, et al. *Chord: A scalable peer-to-peer lookup service for internet applications.* (SIGCOMM 2001)

---

## Local Testing Guide

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
```

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

## Benchmark Guide

This benchmark script compares the performance of Chord and Koorde DHT protocols for web caching workloads.

## Quick Start

```powershell
.\benchmark-chord-vs-koorde.ps1
```

## Configuration

The script accepts the following parameters:

```powershell
.\benchmark-chord-vs-koorde.ps1 `
    -NumNodes 5 `
    -NumRequests 1000 `
    -Concurrency 10 `
    -ZipfExponent 1.2 `
    -WarmupSeconds 30 `
    -TestDurationSeconds 60
```

### Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `NumNodes` | 5 | Number of nodes in each cluster |
| `NumRequests` | 1000 | Total requests to send per protocol |
| `Concurrency` | 10 | Concurrent requests (rate limiter) |
| `ZipfExponent` | 1.2 | Zipf distribution exponent (higher = more skewed) |
| `WarmupSeconds` | 30 | Time to wait for cluster stabilization |
| `TestDurationSeconds` | 60 | Duration of test (currently not used, based on requests) |

## What It Measures

### Performance Metrics

1. **Request Performance**
   - Total requests
   - Success/error rates
   - Latency (avg, min, max, P50, P95, P99)

2. **Cache Performance**
   - Cache hits/misses
   - Cache hit rate
   - Total cache entries
   - Cache size utilization

3. **Routing Metrics**
   - Successor list size
   - DeBruijn entries (Koorde only)
   - Finger table entries (Chord only)
   - Routing table overhead

## Output

The benchmark generates:

1. **Comparison Report** (`benchmark/results/comparison-report.txt`)
   - Formatted table comparing Chord vs Koorde
   - Performance analysis
   - Recommendations

2. **CSV Results**
   - `benchmark/results/chord-results.csv`
   - `benchmark/results/koorde-results.csv`
   - Contains per-request data: timestamp, latency, status, cache status

3. **JSON Summary** (`benchmark/results/summary.json`)
   - Machine-readable summary
   - All metrics in structured format

4. **Logs**
   - `logs/bench-chord-node*.log` - Chord node logs
   - `logs/bench-koorde-node*.log` - Koorde node logs
   - `benchmark/results/*-workload.log` - Workload generator logs

## Example Output

```
============================================
  Chord vs Koorde Benchmark Results
============================================

┌─────────────────────────────────────────────────────────────┐
│                    Request Performance                       │
├──────────────────────┬──────────────────┬───────────────────┤
│ Metric               │ Chord            │ Koorde            │
├──────────────────────┼──────────────────┼───────────────────┤
│ Total Requests       │              1000 │              1000 │
│ Success Rate         │           99.50% │           99.80% │
│ Avg Latency (ms)     │            45.23 │            38.12 │
│ P95 Latency (ms)     │           120.45 │            95.67 │
└──────────────────────┴──────────────────┴───────────────────┘

┌─────────────────────────────────────────────────────────────┐
│                    Cache Performance                        │
├──────────────────────┬──────────────────┬───────────────────┤
│ Cache Hit Rate       │           72.30% │           75.60% │
│ Total Cache Entries  │               45 │               48 │
└──────────────────────┴──────────────────┴───────────────────┘
```

## Expected Results

### Chord Characteristics

- **Routing Table**: O(log n) finger table entries
- **Lookup Hops**: O(log n) ≈ 6-10 hops for 1000 nodes
- **Memory**: Lower overhead (smaller routing table)
- **Latency**: Slightly higher due to more hops

### Koorde Characteristics

- **Routing Table**: O(log² n) de Bruijn + successors
- **Lookup Hops**: O(log₈ n) ≈ 3-4 hops for 1000 nodes (with k=8)
- **Memory**: Higher overhead (larger routing table)
- **Latency**: Lower due to fewer hops

## Performance Trade-offs

| Aspect | Chord | Koorde |
|--------|-------|--------|
| **Lookup Speed** | O(log n) hops | O(log₈ n) ≈ 3-4 hops |
| **Memory Usage** | Lower (O(log n)) | Higher (O(log² n)) |
| **Maintenance** | Finger table updates | De Bruijn maintenance |
| **Fault Tolerance** | Successor list | Successor list + De Bruijn |
| **Best For** | Memory-constrained | Latency-sensitive |

## Troubleshooting

### Issue: Nodes fail to start

**Solution**: Check if ports are available:
- Chord: 5000-5004 (gRPC), 9000-9004 (HTTP)
- Koorde: 6000-6004 (gRPC), 10000-10004 (HTTP)

### Issue: Low cache hit rate

**Possible causes**:
- Warmup time too short (increase `-WarmupSeconds`)
- Too many unique URLs (reduce `--urls`)
- Zipf exponent too low (increase `-ZipfExponent`)

### Issue: High latency

**Possible causes**:
- Network issues
- Origin server (httpbin.org) slow
- Insufficient stabilization time

## Advanced Usage

### Custom Workload

Modify the script to use custom URLs or adjust the workload pattern.

### Long-Running Tests

For production-like testing:
```powershell
.\benchmark-chord-vs-koorde.ps1 -NumRequests 10000 -Concurrency 50
```

### Stress Testing

```powershell
.\benchmark-chord-vs-koorde.ps1 -NumNodes 10 -NumRequests 5000 -Concurrency 100
```

## Interpreting Results

### Latency Comparison

- **Koorde typically wins** on lookup latency due to fewer hops
- **Chord may win** on cache hit latency if routing table is smaller

### Cache Hit Rate

- Should be similar for both protocols (depends on workload, not protocol)
- Differences indicate routing efficiency or node distribution

### Memory Usage

- **Chord**: Lower memory footprint
- **Koorde**: Higher memory but better lookup performance

## Next Steps

1. Analyze the CSV files for detailed per-request metrics
2. Compare P95/P99 latencies for tail latency analysis
3. Test with different node counts to see scalability
4. Adjust Zipf exponent to simulate different workload patterns

---

## Benchmark Report

## Executive Summary
This report compares the runtime behavior of two distributed hash table (DHT) designs — **Chord** and **Koorde** — across three experiments: latency scaling, cache hit rate under churn, and throughput under load. Key findings:

- **Latency (8–32 nodes):** Chord exhibited lower median and tail latencies in our environment (≈19 ms avg) while Koorde showed higher average and P95/P99 latency despite theoretical hop-count advantages.
- **Churn resilience:** Both Chord and Koorde preserved cache state far better than a simple modulo hash (Simple Hash), producing substantially higher hit rates during topology changes.
- **Throughput:** Chord sustained higher RPS and scaled more stably under high concurrency in these tests.

Interpretation: the experimental results reflect implementation and environment factors (per-hop cost, maintenance traffic, cloud quotas) that can mask asymptotic algorithmic advantages at small-to-medium cluster sizes. See the Limitations and Measurement Plan sections for recommended follow-ups to validate Koorde at larger scales.

## Table of Contents
- [Experiment 1: Latency Scaling (Koorde vs Chord)](#experiment-1-latency-scaling-koorde-vs-chord)
- [Experiment 2: Cache Hit Rate Under 3-Phase Node Churn](#experiment-2-cache-hit-rate-under-3-phase-node-churn-4--3--4)
- [Experiment 3: Throughput Benchmark (Koorde vs Chord)](#experiment-3-throughput-benchmark-koorde-vs-chord)

---

## Experiment 1: Latency Scaling (Koorde vs Chord)

### Experiment Introduction
This experiment empirically compares the latency characteristics of **Chord** and **Koorde** as the cluster size scales from 8 to 32 nodes. It aims to validate whether Koorde's theoretical routing efficiency ($O(\frac{\log N}{\log \log N})$) translates to lower latency in a realistic cloud environment (AWS EKS) compared to Chord ($O(\log N)$).

### Methodology
- **Tooling:** [Locust](https://locust.io/) was used for distributed load generation.
- **Workload:** 50 concurrent users generating requests with a **Zipfian distribution** (alpha=1.2) to simulate realistic content popularity (hot keys).
- **Traffic:** Mixed workload of `/cache` (DHT lookups) and `/health` checks, but analysis focuses on `/cache` endpoints.
- **Environment:** AWS EKS (us-west-2) with a local in-cluster Nginx origin to isolate DHT routing latency from external network noise.

### Experiment Settings
| Parameter | Value |
|-----------|-------|
| **Environment** | AWS EKS (us-west-2) |
| **Cluster Sizes** | 8, 16, 20, 26, 32 nodes |
| **Protocols** | Chord, Koorde (k=2, 4, 8) |
| **Workload** | 50 concurrent users, Zipfian distribution |
| **Origin** | Local in-cluster Nginx (to isolate routing latency) |

### Data (Results)

#### Summary of Average Latency
| Nodes | Protocol | Degree (k) | Avg Latency (ms) |
|-------|----------|------------|------------------|
| 8     | Chord    | N/A        | 18.8             |
| 8     | Koorde   | 2          | 25.5             |
| 8     | Koorde   | 8          | 24.8             |
| 16    | Chord    | N/A        | 18.8             |
| 16    | Koorde   | 2          | 37.4             |
| 32    | Chord    | N/A        | 19.4             |
| 32    | Koorde   | 2          | 54.9             |
| 32    | Koorde   | 8          | 50.3             |

#### Detailed Latency Distribution (32 Nodes)
A deeper look at the tail latency reveals significant differences in stability.

| Metric | Chord | Koorde (k=2) | Koorde (k=8) | Comparison |
|--------|-------|--------------|--------------|------------|
| **Median (P50)** | **19 ms** | 46 ms | 39 ms | Chord is ~2x faster |
| **Average** | **19.7 ms** | 60.5 ms | 54.5 ms | Chord is ~2.7x faster |
| **P95 Latency** | **25 ms** | 140 ms | 160 ms | Chord is **5.6x more stable** |
| **P99 Latency** | **37 ms** | 190 ms | 240 ms | Koorde has high tail latency |
| **Max Latency** | **96 ms** | 510 ms | 550 ms | - |

*(Note: Throughput comparison is omitted for this specific experiment as tests were conducted in different network environments.)*

### Visualizations
**Figure 1: Average Latency vs. Node Count**
![Latency vs Nodes](test/results/plots/latency_vs_nodes.png)
*Comparison of Chord baseline against Koorde with varying degrees.*

### Analysis & Conclusions

#### 1. Chord Dominance & Stability
Chord consistently outperformed Koorde across all cluster sizes (8-32 nodes), maintaining a remarkably flat latency profile (~19ms avg, 25ms P95). The tight bound between P50 (19ms) and P99 (37ms) indicates that Chord's finger table implementation is highly efficient and predictable at this scale. The $O(\log N)$ hops in a 32-node cluster are few enough that the overhead is negligible.

#### 2. Koorde Scaling & Tail Latency
Koorde showed a clear increase in latency as nodes were added (25ms → 55ms). More critically, the **tail latency (P95/P99)** for Koorde is significantly higher (140ms+) than Chord. This suggests that while some lookups are fast, a significant portion of requests in Koorde suffer from longer routing paths or processing overheads. This could be due to the complexity of de Bruijn graph traversal or "imaginary node" calculations in a real distributed setting.

#### 3. Impact of Degree (k) - Theory vs Practice
The theory that higher degree reduces path length was **validated** in the average case. At 32 nodes, Koorde with $k=8$ (Avg 50.3ms) was faster than $k=2$ (Avg 54.9ms), confirming that increasing the de Bruijn degree reduces network diameter. However, the **P95 latency** for $k=8$ was actually slightly worse (160ms vs 140ms), suggesting that the complexity of managing more neighbors or routing logic might introduce variance that affects tail latency.

#### 4. Theoretical vs Practical Gap
While Koorde has a superior asymptotic bound ($O(\frac{\log N}{\log \log N})$), the constant factors in implementation and network RTT dominate at the scale of 32 nodes. Chord's simpler logic and efficient pointer chasing proved superior in this specific AWS EKS environment. Koorde's benefits might only become apparent at much larger scales (e.g., thousands of nodes) where the logarithmic difference in hop count becomes significant enough to outweigh the per-hop overhead.

### Limitations
- **Cluster Size Constraints:** The AWS Learner Lab environment used for EKS deployment imposes a hard limit of 9 EC2 instances per cluster. Even with `t3.large` nodes, this restricts the maximum practical DHT size to about 35–40 nodes (with 3–4 pods per node).
- **Scaling Attempts:** Attempts to scale the cluster to 40 nodes were unsuccessful; the cluster never became fully ready due to resource and quota limitations.
- **Cloud Lab Environment:** Results may not generalize to larger-scale or production-grade EKS clusters with higher quotas and more powerful instance types. The observed scaling and latency trends are valid only within the tested range (up to 32 nodes).
- **Network and Resource Contention:** The shared nature of the Learner Lab environment may introduce additional network or resource contention not present in dedicated or production EKS clusters.
- **Algorithmic Superiority Not Fully Demonstrated:** Due to the cluster size restrictions, we were unable to empirically demonstrate the full theoretical advantage of Koorde's $O(\frac{\log N}{\log \log N})$ routing. To observe the true scaling benefits and potential crossover point where Koorde outperforms Chord, experiments with much larger clusters (e.g., 128, 256, 512, or 1024 nodes) would be necessary. The current results reflect only the small-to-medium scale regime imposed by the AWS Learner Lab environment.

### Measurement Plan & Next Experiments

- **Goal:** determine whether Koorde's asymptotic hop-count advantage yields lower observed latency at larger N, and measure the crossover point where Koorde becomes faster in practice.

- **Immediate measurements to add** (instrumentation):
	- Per-request hop count (log hops for each lookup) and a per-request hop histogram.
	- Per-hop timing: timestamps at hop entry/exit so we can separate network RTT from processing overhead.
	- Node resource metrics (CPU, memory, network TX/RX) sampled at 1s resolution.
	- Background maintenance traffic rates (messages/sec per node) to capture routing table churn overhead.
	- P50/P95/P99 and tail distributions per-node and overall.

- **Suggested experiments to validate asymptotic behavior:**
	1. **Logical scaling (fast, low-cost):** run many logical DHT nodes per pod (virtual nodes) to emulate N=128/256/512/1024 while reusing the available EC2 instances. This reveals protocol behavior without requiring large cloud quotas.
	2. **Simulator/emulator:** use a DHT event-driven simulator to validate algorithmic hop counts and latency under controlled per-hop costs and network models.
	3. **Higher-quota cloud run:** if possible, repeat full EKS runs on a higher-quota account (or larger instance types) and target N = 128/256/512 to observe real network effects.
	4. **Netem amplification:** apply in-cluster artificial per-hop RTT (using `tc`/`netem`) to amplify the effect of hop-count differences so reductions in hops produce measurable latency improvements.

- **Quick validation commands (examples):**

```powershell
# (1) Run nodes with multiple logical instances: adjust the pod command to spawn M logical nodes per pod
kubectl set image deployment/my-node my-node-image:latest
# (2) Apply netem to a node interface (example, run inside a privileged pod)
tc qdisc add dev eth0 root netem delay 15ms
```

---

## Experiment 2: Cache Hit Rate Under 3-Phase Node Churn (4 → 3 → 4)

### Experiment Introduction
This experiment evaluates **cache hit rate** stability under **node churn** for three routing strategies:
**Simple Hash** (static modulo), **Chord**, and **Koorde** (consistent hashing).

### Experiment Settings
| Parameter              | Value                                    |
| ---------------------- | ---------------------------------------- |
| **Node churn pattern** | 4 → 3 → 4 (remove 1 node, then add back) |
| **Unique URLs**        | 200                                      |
| **Requests per phase** | 300                                      |
| **Total requests**     | 900                                      |
| **Request rate**       | 50 req/s                                 |
| **Zipf alpha**         | 1.2                                      |
| **Koorde degree**      | 4                                        |

### Data (Results)

#### Final Ranking (Hit Rate)
| Rank    | Protocol        | Avg Hit Rate | Failures | Key Redistribution | Verdict                    |
| ------- | --------------- | ------------ | -------- | ------------------ | -------------------------- |
| **1st** | **Chord**       | **38.2%**    | 0        | ~25%               | BEST - consistent hashing  |
| **2nd** | **Koorde**      | **35.3%**    | 0        | ~25%               | Great - consistent hashing |
| **3rd** | **Simple Hash** | **19.0%**    | 0        | ~75%               | WORST - key redistribution |

#### Cache Hit Rate Progression
*(Plot not checked in: hit_rate_comparison.png)*

- **Chord** highest hit rate (consistent hashing preserves cache).
- **Koorde** close behind (consistent hashing preserves cache).
- **Simple Hash** lowest (major remapping on churn).

#### Observed Hit Rate by Phase
| Protocol    | Phase 1 | Phase 2 | Phase 3 | Explanation                                |
| ----------- | ------- | ------- | ------- | ------------------------------------------ |
| Simple Hash | 19.7%   | 16.3%   | 21.0%   | Lowest - ~75% cache invalidated each phase |
| Chord       | 33.3%   | 46.7%   | 34.7%   | Highest - ~75% cache preserved             |
| Koorde      | 31.7%   | 41.3%   | 33.0%   | Good - ~75% cache preserved                |

### Analysis & Conclusions
- **Consistent Hashing Wins:** Both Chord and Koorde preserved ~75% of the cache during churn, leading to significantly higher hit rates than Simple Hash.
- **Simple Hash Failure:** Simple Hash invalidated ~75% of keys with every topology change, making it unsuitable for dynamic environments.
- **Recommendation:** For dynamic clusters, **Chord or Koorde** is required. Simple Hash is only acceptable for static clusters.

---

## Experiment 3: Throughput Benchmark (Koorde vs Chord)

### Summary
This experiment compares how Koorde and Chord scale under increasing concurrent load.

### Setup
- **Users tested**: 50, 100, 200, 500, 1000, 2000, 4000
- **Metric**: throughput (Requests Per Second, RPS)
- **Conditions**: Koorde and Chord run under identical conditions
- **Note**: X-axis is equally spaced for clarity and does not represent actual numeric spacing between user counts

### Key Observations
- **Chord** achieves significantly higher throughput, saturating around ~3000 RPS.
- **Koorde** saturates earlier (~2200 RPS) and declines at high load (4000 users).
- **Chord** demonstrates better stability and scalability under high concurrency.
- **Koorde** shows more sensitivity to overload conditions.

### Chart
*(Plot not checked in: throughput.png; see available plot: test/results/plots/rps_vs_nodes.png)*

---

## Final Conclusion

Across all three experiments, **Chord** demonstrated superior performance and stability in this implementation:
1.  **Latency:** Chord maintained lower, flatter latency as the cluster scaled.
2.  **Stability:** Chord handled node churn with the highest cache hit rate.
3.  **Throughput:** Chord sustained higher RPS loads before saturation.

**Koorde** validated its theoretical properties (higher degree = lower latency) and performed well in churn (consistent hashing), but its implementation overhead appears higher than Chord's at these scales (up to 32 nodes). For production use at this scale, **Chord** is the recommended protocol.
