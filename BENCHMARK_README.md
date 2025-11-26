# Chord vs Koorde Web Cache Benchmark

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

