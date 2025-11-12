# Local Deployment with Jaeger (Tracing & Web Cache Testing)

This deployment starts a minimal KoordeDHT network locally using **Docker Compose**.

## What's Included

- **Jaeger** for distributed tracing via OpenTelemetry
- **Bootstrap node** as the initial network entry point
- **Multiple Koorde nodes** forming the DHT ring with web cache
- **Interactive client** for DHT operations (`put`, `get`, `delete`, `lookup`)
- **Web cache HTTP API** on port 8080

## Quick Start

### 1. Start the Cluster

```bash
docker-compose up -d --scale node=5
```

This starts:
- 1 bootstrap node (entry point)
- 5 additional Koorde nodes
- 1 Jaeger instance
- 1 interactive client

### 2. Wait for Stabilization

```bash
# Wait 30-60 seconds for the DHT to stabilize
sleep 60
```

### 3. Test Web Cache

```bash
# Test cache functionality
./test_cache.sh
```

Or manually:

```bash
# First request (MISS - fetches from origin)
curl "http://localhost:8080/cache?url=https://httpbin.org/json"

# Second request (HIT - served from cache)
curl "http://localhost:8080/cache?url=https://httpbin.org/json"

# Check cache headers
curl -I "http://localhost:8080/cache?url=https://httpbin.org/json"
# Response:
# X-Cache: HIT-LOCAL
# X-Node-ID: 0x1a2b3c4d...
# X-Latency-Ms: 2.15
```

### 4. View Metrics

```bash
curl http://localhost:8080/metrics | jq
```

Output:
```json
{
  "node": {
    "id": "0x0139a675cf05ffab3b",
    "addr": "bootstrap:4000"
  },
  "cache": {
    "hits": 450,
    "misses": 50,
    "hit_rate": 0.9,
    "entry_count": 125,
    "size_bytes": 52428800,
    "utilization": 0.05
  },
  "hotspots": {
    "count": 2,
    "urls": ["https://popular.com/video.mp4"]
  },
  "routing": {
    "successor_count": 8,
    "debruijn_count": 8,
    "has_predecessor": true
  }
}
```

### 5. Access Jaeger UI

Open your browser:
```
http://localhost:16686
```

**What to look for**:
- **DHT Lookup traces**: See the O(log n) hop path
- **Cache operations**: Local cache hits vs DHT forwarding
- **Hotspot distribution**: Random node selection for popular URLs

---

## DHT Client (Interactive)

```bash
docker exec -it koorde-client /usr/local/bin/koorde-client --addr=bootstrap:4000
```

Available commands:

```
koorde[bootstrap:4000]> put mykey myvalue
Put succeeded (key=mykey, value=myvalue) | latency=15ms

koorde[bootstrap:4000]> get mykey
Get succeeded (key=mykey, value=myvalue) | latency=8ms

koorde[bootstrap:4000]> lookup 0x1a2b3c4d5e6f
Lookup result: successor=0x1a2b3c... (10.0.0.5:4000) | latency=12ms

koorde[bootstrap:4000]> getrt
Routing table:
  Self: 0x0139a675... (bootstrap:4000)
  Predecessor: 0x00ebb345... (node-3:4000)
  Successors:
    [0] 0x017711a2... (node-1:4000)
    [1] 0x01a724dc... (node-2:4000)
    ...
  DeBruijn List:
    [0] 0x03da43dc... (node-4:4000)
    [1] 0x02d21ee0... (node-5:4000)
    ...

koorde[bootstrap:4000]> exit
```

---

## Configuration

### Node Configuration

Edit `common_node.env` to customize:

```bash
# DHT settings
DHT_ID_BITS=66              # Identifier space size
DEBRUIJN_DEGREE=8           # de Bruijn degree (2, 4, 8, 16)
SUCCESSOR_LIST_SIZE=8       # Fault tolerance

# Cache settings
CACHE_CAPACITY_MB=1024      # Cache size per node
CACHE_DEFAULT_TTL=3600      # TTL in seconds
CACHE_HOTSPOT_THRESHOLD=1000.0  # Requests/sec
CACHE_HOTSPOT_DECAY=0.65    # Decay rate γ

# Tracing
TRACING_ENABLED=true
TRACING_ENDPOINT=jaeger:4317
```

---

## Testing Web Cache

### Manual Testing

```bash
# Test 1: Simple cache flow
curl "http://localhost:8080/cache?url=https://httpbin.org/json"

# Test 2: Large content
curl "http://localhost:8080/cache?url=https://httpbin.org/image/jpeg"

# Test 3: Multiple URLs
for i in {1..10}; do
  curl "http://localhost:8080/cache?url=https://httpbin.org/uuid"
done

# Test 4: Hotspot simulation (same URL many times)
for i in {1..100}; do
  curl "http://localhost:8080/cache?url=https://httpbin.org/get" &
done
wait
```

### Automated Test Script

```bash
./test_cache.sh
```

This script:
1. Cleans up previous deployment
2. Starts cluster with 5 nodes
3. Waits for stabilization
4. Runs health checks
5. Tests cache MISS (first request)
6. Tests cache HIT (second request)
7. Shows metrics

---

## Observability

### Jaeger Traces

1. Open http://localhost:16686
2. Select service: `KoordeDHT-Node`
3. Click **Find Traces**

**Interesting traces to explore**:
- `FindSuccessor`: DHT lookup with de Bruijn hops
- `HandleCacheRequest`: Web cache request flow
- `fixDeBruijn`: Periodic stabilization

### Logs

```bash
# View logs from all nodes
docker-compose logs -f

# View logs from specific node
docker-compose logs -f bootstrap

# View cache-related logs
docker-compose logs -f | grep -i cache
```

### Debug Endpoint

```bash
# Detailed routing table
curl http://localhost:8080/debug | jq
```

---

## Architecture

```
┌─────────────┐
│   Client    │
└──────┬──────┘
       │ HTTP :8080
       ↓
┌─────────────────────┐
│  Bootstrap Node     │
│  ┌───────────────┐  │
│  │  Web Cache    │  │
│  │  (LRU + TTL)  │  │
│  └───────────────┘  │
│  ┌───────────────┐  │
│  │  DHT Routing  │  │
│  │  (Koorde)     │  │
│  └───────────────┘  │
└─────────┬───────────┘
          │ gRPC :4000
          ↓
    ┌─────┴─────┬──────┬──────┐
    ↓           ↓      ↓      ↓
┌───────┐  ┌───────┐  ...  ┌───────┐
│Node 1 │  │Node 2 │       │Node N │
│Cache  │  │Cache  │       │Cache  │
└───────┘  └───────┘       └───────┘
```

---

## Shutdown

```bash
# Stop and remove containers
docker-compose down

# Also remove volumes
docker-compose down -v
```

---

## Example Results

See `results/traces-*.json` for example Jaeger traces showing:
- DHT lookup with 3-4 hops (k=8 de Bruijn)
- Cache hit latency < 5ms
- Hotspot detection and random distribution
- Fault tolerance during node failures

---

## Next Steps

- Try [Automated Testing](../test/README.md) with churn simulation
- Deploy to [AWS](../demonstration/README.md) for production testing
- Generate workload with `cache-workload` tool
- Experiment with different cache configurations

---

## Troubleshooting

**Issue**: Nodes not connecting
```bash
# Check bootstrap node is running
docker-compose ps bootstrap

# Check network connectivity
docker-compose exec node-1 ping bootstrap
```

**Issue**: Cache not working
```bash
# Check HTTP server is running
curl http://localhost:8080/health

# Check logs
docker-compose logs bootstrap | grep -i "http"
```

**Issue**: Jaeger not showing traces
```bash
# Verify tracing is enabled
docker-compose exec bootstrap env | grep TRACING

# Check Jaeger is running
curl http://localhost:16686
```
