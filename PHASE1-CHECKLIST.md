# Phase 1 Testing Checklist

Verify everything works locally before Phase 2 (cloud deployment with 1000+ nodes).

## Phase 1 Goals

- ✓ Build and run locally without Docker
- ✓ Test basic DHT operations
- ✓ Test web cache functionality
- ✓ Verify multi-node operation
- ✓ Test cache workload with Zipf distribution
- ✓ Collect baseline performance metrics

---

## Pre-Flight Checks

### 1. Build System

```bash
# Verify Go version
go version  # Should be 1.25+

# Test build
go build -o bin/ ./cmd/...

# Check binaries exist
ls -lh bin/
# Should see:
# - koorde-node
# - koorde-client
# - koorde-tester
# - cache-workload
```

### 2. Dependencies

```bash
# Verify all dependencies
go mod verify
go mod tidy

# Check for any issues
go vet ./...
```

### 3. Unit Tests

```bash
# Run existing tests
go test ./internal/domain/...

# Verify tests pass
echo "Tests: $(go test ./... 2>&1 | grep -c PASS) passed"
```

---

## Phase 1 Testing Steps

### Test 1: Single Node (Basic Functionality)

```bash
# Start bootstrap node
./bin/koorde-node --config config/node/config.yaml

# In another terminal:
# Test 1.1: Health check
curl "http://localhost:8080/health"
# Expected: {"healthy":true,"status":"READY",...}

# Test 1.2: Cache miss
curl "http://localhost:8080/cache?url=https://httpbin.org/json"
# Expected: JSON response + X-Cache: MISS-ORIGIN

# Test 1.3: Cache hit
curl "http://localhost:8080/cache?url=https://httpbin.org/json"
# Expected: Same response + X-Cache: HIT-LOCAL + faster

# Test 1.4: Metrics
curl "http://localhost:8080/metrics" | jq '.cache'
# Expected: hits: 1, misses: 1, hit_rate: 0.5

# Test 1.5: DHT operations
./bin/koorde-client --addr localhost:4000 <<EOF
put testkey testvalue
get testkey
getrt
exit
EOF
# Expected: Put succeeded, Get succeeded, Routing table shown
```

**Status**: [ ] Passed  [ ] Failed

---

### Test 2: Multi-Node Cluster (DHT Routing)

```bash
# Start 5-node cluster
./test-local-cluster.sh 5

# Wait for stabilization (15 seconds)

# Test 2.1: Verify all nodes healthy
for port in 8080 8081 8082 8083 8084; do
  curl -s "http://localhost:${port}/health" | jq -r '.status'
done
# Expected: All show "READY"

# Test 2.2: Check routing tables
./bin/koorde-client --addr localhost:4000 <<EOF
getrt
exit
EOF
# Expected: Should show 8 successors, 8 de Bruijn entries

# Test 2.3: Test cache distribution
curl "http://localhost:8080/cache?url=https://httpbin.org/uuid"
curl "http://localhost:8081/cache?url=https://httpbin.org/uuid"
curl "http://localhost:8082/cache?url=https://httpbin.org/uuid"
# Expected: Different nodes may forward to responsible node

# Test 2.4: Verify DHT consistency
./bin/koorde-client --addr localhost:4001 <<EOF
put distributed-key distributed-value
exit
EOF

./bin/koorde-client --addr localhost:4002 <<EOF
get distributed-key
exit
EOF
# Expected: Value retrieved successfully from any node
```

**Status**: [ ] Passed  [ ] Failed

---

### Test 3: Cache Performance

```bash
# Run workload with Zipf distribution
./bin/cache-workload \
  --target http://localhost:8080 \
  --urls 100 \
  --requests 1000 \
  --rate 50 \
  --zipf 0.9 \
  --output phase1-results.csv

# Expected output:
# - Success rate: >95%
# - Average latency: <100ms
# - Hit rate: 60-80% (Zipf makes popular URLs cached)

# Check metrics after workload
curl "http://localhost:8080/metrics" | jq '.cache'
# Expected:
# - hit_rate: 0.6-0.8
# - hits: 600-800
# - misses: 200-400
```

**Status**: [ ] Passed  [ ] Failed

**Baseline Metrics**:
- Average latency: _____ ms
- Hit rate: _____ %
- Success rate: _____ %

---

### Test 4: Hotspot Detection

```bash
# Generate hotspot traffic (same URL repeatedly)
for i in {1..200}; do
  curl -s "http://localhost:8080/cache?url=https://httpbin.org/json" > /dev/null &
done
wait

# Check hotspot detection
curl "http://localhost:8080/metrics" | jq '.hotspots'
# Expected: Should show hotspot detected with count > 0

# Test random distribution
# Request should go to different nodes when hotspot
curl -s "http://localhost:8080/cache?url=https://httpbin.org/json" -I | grep "X-Node-ID"
curl -s "http://localhost:8080/cache?url=https://httpbin.org/json" -I | grep "X-Node-ID"
# Expected: May show different node IDs due to random distribution
```

**Status**: [ ] Passed  [ ] Failed

---

### Test 5: Node Failure & Recovery

```bash
# Kill one node
PIDS=($(cat logs/pids.txt))
kill ${PIDS[2]}  # Kill node-2

# Wait 5 seconds
sleep 5

# Test DHT still works
curl "http://localhost:8080/health"
# Expected: Still READY

# Test cache still works
curl "http://localhost:8080/cache?url=https://httpbin.org/json"
# Expected: Still returns data

# Check routing table adapted
./bin/koorde-client --addr localhost:4000 <<EOF
getrt
exit
EOF
# Expected: Routing table still valid, may show different successors
```

**Status**: [ ] Passed  [ ] Failed

---

### Test 6: Stress Test

```bash
# High-rate workload
./bin/cache-workload \
  --target http://localhost:8080 \
  --urls 1000 \
  --requests 10000 \
  --rate 200 \
  --zipf 0.9 \
  --output phase1-stress.csv

# Check for errors in logs
grep -i "error\|panic\|fatal" logs/*.log

# Verify no crashes
for port in 8080 8081 8082 8083 8084; do
  curl -s "http://localhost:${port}/health" > /dev/null && echo "Node on port ${port}: OK"
done
```

**Status**: [ ] Passed  [ ] Failed

**Stress Test Metrics**:
- Total requests: _____
- Failed requests: _____
- Average latency: _____ ms
- Max latency: _____ ms
- Cache hit rate: _____ %

---

## Phase 1 Completion Criteria

- [ ] All binaries build successfully
- [ ] Single node starts and responds
- [ ] Multi-node cluster forms DHT ring
- [ ] Cache MISS → fetches from origin
- [ ] Cache HIT → serves from local cache
- [ ] DHT lookup works across nodes
- [ ] Hotspot detection activates
- [ ] Node failure doesn't break cluster
- [ ] Workload generator completes successfully
- [ ] No crashes under stress test
- [ ] Metrics endpoint provides accurate data

---

## Troubleshooting Phase 1

### Issue: Node won't start

```bash
# Check logs
cat logs/node0.log

# Common causes:
# - Port already in use: netstat -an | grep 4000
# - Config error: ./bin/koorde-node --config config/node/config.yaml (check output)
```

### Issue: Nodes can't find each other

```bash
# Check bootstrap peers in config
cat config/local-cluster/node1.yaml | grep peers

# Verify first node is running
curl "http://localhost:8080/health"

# Check connectivity
telnet localhost 4000  # Should connect
```

### Issue: Cache not working

```bash
# Check cache is enabled
curl "http://localhost:8080/metrics" | grep cache

# Check logs for errors
grep -i cache logs/node0.log

# Verify HTTP port
netstat -an | grep 8080
```

### Issue: High latency

```bash
# Check if origin fetch is slow
time curl "https://httpbin.org/json"

# Reduce request rate
./bin/cache-workload --rate 10

# Check resource usage
top  # or Task Manager on Windows
```

---

## Next Steps After Phase 1

Once all tests pass:

1. **Document baseline metrics** (save results.csv)
2. **Review logs** for any warnings
3. **Optimize configuration** if needed
4. **Test with different cache sizes** (256MB, 512MB, 1GB)
5. **Test with different Zipf alphas** (0.8, 0.9, 1.1)
6. **Prepare for Phase 2**: Cloud deployment with 1000+ nodes

---

## Quick Test (1 minute)

```bash
# Build
go build -o bin/ ./cmd/...

# Start single node
./bin/koorde-node --config config/node/config.yaml &
sleep 5

# Test
curl "http://localhost:8080/health"
curl "http://localhost:8080/cache?url=https://httpbin.org/json"

# Stop
pkill koorde-node
```

**If this works, you're ready for full Phase 1 testing!**

