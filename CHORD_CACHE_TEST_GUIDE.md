# Chord Cache Integration Test Guide

This guide helps you test the Chord cache operations after the fixes.

## Quick Test (2 Nodes)

### Step 1: Start Node 1 (Bootstrap)

```powershell
.\bin\node.exe -config config/chord-test/node1.yaml
```

Or use the existing test config:
```powershell
.\bin\node.exe -config test-node1-chord.yaml
```

**Expected output:**
- Node starts on port 4000 (gRPC) and 8080 (HTTP)
- Creates new DHT ring
- Logs: "Initialized Chord node"

### Step 2: Start Node 2 (Join)

In a new terminal:
```powershell
.\bin\node.exe -config test-node2-chord.yaml
```

**Expected output:**
- Node starts on port 4001 (gRPC) and 8081 (HTTP)
- Joins existing ring
- Logs: "join: completed successfully"

### Step 3: Wait for Stabilization

Wait **10-15 seconds** for:
- Finger table to populate (fixFinger runs every 100ms)
- Predecessor to be set
- Successor list to update

### Step 4: Test Cache Operations

#### Test 1: Health Check
```powershell
curl http://localhost:8080/health
curl http://localhost:8081/health
```

**Expected:** Both return `{"healthy":true,"status":"READY"}`

#### Test 2: Debug Endpoint (Verify Finger Table)
```powershell
curl http://localhost:8080/debug | ConvertFrom-Json | Select-Object -ExpandProperty routing
curl http://localhost:8081/debug | ConvertFrom-Json | Select-Object -ExpandProperty routing
```

**Expected:**
- `debruijn_count: 0` (Chord doesn't use de Bruijn)
- `successor_count: 8` (or configured size)
- `has_predecessor: true`

#### Test 3: Cache Request (First Time - MISS)
```powershell
curl "http://localhost:8080/cache?url=https://httpbin.org/json" -v
```

**Expected:**
- HTTP 200 OK
- Header: `X-Cache: MISS-ORIGIN` or `X-Cache: MISS-DHT`
- Content: JSON from httpbin.org
- Header: `X-Node-ID: <node-id>`

#### Test 4: Cache Request (Second Time - HIT)
```powershell
curl "http://localhost:8080/cache?url=https://httpbin.org/json" -v
```

**Expected:**
- HTTP 200 OK
- Header: `X-Cache: HIT-LOCAL`
- Fast response (cached)

#### Test 5: Cross-Node Cache Request
```powershell
curl "http://localhost:8081/cache?url=https://httpbin.org/json" -v
```

**Expected:**
- If URL hashes to Node 1: `X-Cache: MISS-DHT` (forwarded to Node 1)
- If URL hashes to Node 2: `X-Cache: MISS-ORIGIN` (Node 2 fetches)
- No 503 errors!

#### Test 6: Metrics
```powershell
curl http://localhost:8080/metrics | ConvertFrom-Json | Select-Object -ExpandProperty cache
curl http://localhost:8081/metrics | ConvertFrom-Json | Select-Object -ExpandProperty cache
```

**Expected:**
- `hits` and `misses` counters
- `hit_rate` between 0 and 1
- `entry_count` > 0 after cache operations

## Automated Test

Run the PowerShell test script:

```powershell
.\test-chord-cache.ps1
```

This will:
1. Build the node binary if needed
2. Create test configurations
3. Start 3 nodes
4. Wait 15 seconds for stabilization
5. Run all tests automatically
6. Display results

## What to Verify

### ✅ Success Indicators

1. **No 503 Errors**: All cache requests return 200 OK
2. **Finger Table Populated**: Debug endpoint shows routing table is active
3. **Cache Hits Work**: Second request to same URL returns `HIT-LOCAL`
4. **Cross-Node Routing**: Requests are correctly forwarded to responsible nodes
5. **Metrics Tracked**: Cache metrics show hits/misses

### ❌ Failure Indicators

1. **503 Service Unavailable**: Indicates lookup/routing failure
2. **Empty Finger Table**: All fingers are nil (fixFinger not working)
3. **No Predecessor**: Ring not properly formed
4. **Cache Always MISS**: Ownership check failing

## Troubleshooting

### Issue: 503 Errors

**Check:**
1. Are both nodes running?
2. Did stabilization complete? (wait 10-15 seconds)
3. Check logs for errors: `Get-Content logs/chord-node*.log -Tail 50`

**Fix:**
- Ensure nodes can communicate (check firewall)
- Verify bootstrap peers are correct
- Check that finger table is populating (wait longer)

### Issue: Finger Table Empty

**Check:**
```powershell
# Check if fixFinger is running
Get-Content logs/chord-node1.log | Select-String "fixFinger"
```

**Expected:** Logs showing "fixFinger: updated finger"

**Fix:**
- Wait longer (finger table updates every 100ms, cycles through all fingers)
- Check for errors in logs

### Issue: Cache Always MISS

**Check:**
- Ownership check: `urlHash.Between(pred.ID, self.ID)`
- Predecessor is set: `/debug` endpoint shows `has_predecessor: true`

**Fix:**
- Ensure predecessor is set (stabilization must complete)
- Check that URL hash falls in correct interval

## Expected Test Results

After running tests, you should see:

```
Test 1: Health Check
  ✓ All nodes healthy

Test 2: Debug Endpoint
  ✓ debruijn_count: 0 (Chord)
  ✓ successor_count: 8
  ✓ has_predecessor: true

Test 3: Cache Operations
  ✓ First request: MISS-ORIGIN or MISS-DHT
  ✓ Second request: HIT-LOCAL
  ✓ Cross-node routing works

Test 4: Metrics
  ✓ Hits > 0
  ✓ Misses > 0
  ✓ Hit rate calculated correctly
```

## Next Steps

If all tests pass:
- ✅ Chord cache integration is working!
- ✅ Finger table maintenance is functional
- ✅ Cache operations are routing correctly

If tests fail:
- Check logs in `logs/chord-node*.log`
- Verify fixes were applied correctly
- Report specific error messages

