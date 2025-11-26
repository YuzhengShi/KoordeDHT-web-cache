# Chord DHT Integration Testing Guide

This guide explains how to deploy and test the Chord DHT implementation in a local environment.

## Prerequisites

- Go 1.21+ installed
- Docker (optional, for container-based testing)
- Access to the project root: `d:\CS6650\KoordeDHT-web-cache`

## Quick Start: Local Testing

### 1. Build the Node Binary

```bash
cd d:\CS6650\KoordeDHT-web-cache
go build -o node.exe ./cmd/node
```

### 2. Create Chord Configuration

Create a test configuration file `config-chord.yaml`:

```yaml
logger:
  active: true
  level: debug
  encoding: console

dht:
  id_bits: 16
  protocol: chord  # ← Chord protocol selection
  mode: tcp
  bootstrap:
    mode: static
    peers: []  # Empty for first node
  debruijn:
    degree: 2
    fix_interval: 5s
  fault_tolerance:
    successor_list_size: 3
    stabilization_interval: 2s
    failure_timeout: 5s
  storage:
    fix_interval: 10s

node:
  id: ""  # Auto-generate
  bind: "0.0.0.0"
  host: ""  # Auto-detect
  port: 4000

cache:
  capacity_mb: 100
  http_port: 8080
  hotspot_threshold: 10.0
  hotspot_decay_rate: 0.9

telemetry:
  tracing:
    enabled: false
```

### 3. Start First Node (Bootstrap)

```bash
# Terminal 1
./node.exe -config config-chord.yaml
```

The node will:
- Initialize with Chord protocol
- Create a new DHT ring (single node)
- Start HTTP cache server on port 8080
- Start gRPC server on port 4000

### 4. Start Second Node (Join Existing Ring)

Create `config-chord-node2.yaml` with different ports:

```yaml
# ... same as above, except:
node:
  port: 4001
  bootstrap:
    mode: static
    peers: ["127.0.0.1:4000"]  # First node's address

cache:
  http_port: 8081
```

```bash
# Terminal 2
./node.exe -config config-chord-node2.yaml
```

The second node will:
- Join the existing Chord ring via `127.0.0.1:4000`
- Find its position using Chord's finger table routing
- Start stabilization to build finger table

### 5. Verify Cluster Formation

Check node health and routing tables:

```bash
# Node 1 debug endpoint
curl http://localhost:8080/debug

# Node 2 debug endpoint
curl http://localhost:8081/debug
```

Expected response:
```json
{
  "self": {"id": "0x1234", "addr": "127.0.0.1:4000"},
  "predecessor": {"id": "0x5678", "addr": "127.0.0.1:4001"},
  "successors": [
    {"id": "0x5678", "addr": "127.0.0.1:4001"}
  ],
  "de_bruijn_list": null,  // Chord doesn't use de Bruijn
  "routing_table_bytes": 32
}
```

### 6. Test Cache Operations

```bash
# Store a URL via node 1
curl "http://localhost:8080/cache?url=https://example.com"

# Retrieve from node 2 (should forward to correct node)
curl "http://localhost:8081/cache?url=https://example.com"

# Check metrics
curl http://localhost:8080/metrics
curl http://localhost:8081/metrics
```

## Comparison: Koorde vs Chord

### Running Parallel Tests

**Koorde Cluster:**
```bash
# Modify config-koorde.yaml:
dht:
  protocol: koorde
  
# Start 3 nodes on ports 4000, 4001, 4002
```

**Chord Cluster:**
```bash
# Modify config-chord.yaml:
dht:
  protocol: chord
  
# Start 3 nodes on ports 5000, 5001, 5002
```

### Metrics to Compare

1. **Routing Table Size**:
   - Koorde: O(log²N) - De Bruijn + successor list
   - Chord: O(log N) - Finger table + successor list
   
   Check `/debug` endpoint's `routing_table_bytes`

2. **Lookup Latency**:
   - Measure time from request to response
   - Check `X-Latency-Ms` header in cache responses

3. **Stabilization Overhead**:
   - Monitor logs for stabilization frequency
   - Chord requires `fixFingers`, `stabilize`, `checkPredecessor`
   - Koorde requires de Bruijn maintenance

4. **Network Traffic**:
   - Count gRPC calls in logs
   - Chord: Finger table lookups (log N hops)
   - Koorde: Imaginary step routing (log² N routing table, but potentially fewer hops)

## Known Limitations

- ⚠️ **Finger Table Maintenance**: `fixFinger()` in Chord is currently stubbed. Finger table updates rely on manual setup or initial successor forwarding.
- ℹ️ **Network Size Estimation**: Chord's `EstimateNetworkSize()` returns hardcoded value.
- ℹ️ **Single-Machine Testing**: This guide uses localhost. For multi-machine testing, adjust `host` and `bootstrap.peers` in configs.

## Troubleshooting

**Issue**: Second node fails to join
- **Solution**: Verify first node is running and accessible at the bootstrap address
- Check firewall/port availability

**Issue**: Routing loops or incorrect forwarding
- **Solution**: Chord's finger table may be incomplete. Wait for stabilization (2-5 seconds) or check logs for errors

**Issue**: Cache inconsistency
- **Solution**: Verify nodes have converged (check `/debug` for correct predecessor/successor)

## Next Steps

1. **Automated Integration Tests**: Create test scripts that:
   - Start N nodes
   - Verify ring formation
   - Execute Put/Get operations
   - Measure latency and consistency

2. **Performance Benchmarks**: Use `deploy/test/` or create custom workload generator
   - Concurrent requests
   - Cache hit/miss ratios
   - Network partitioning scenarios

3. **Visualization**: Add monitoring dashboard (Grafana + Prometheus) to observe:
   - Finger table structure
   - Routing paths
   - Stabilization events
