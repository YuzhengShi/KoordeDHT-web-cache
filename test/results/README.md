# Test Results Analysis

This directory contains performance test results comparing **Local** and **AWS EKS** deployments of the Koorde DHT web cache.

## Directory Structure

```
results/
├── 8nodes/          # Tests with 8 nodes
├── 16nodes/         # Tests with 16 nodes
├── 32nodes/         # Tests with 32 nodes
├── analysis/        # Generated analysis reports and plots
└── README.md        # This file
```

## File Naming Convention

- **Local tests**: `local-{param}_stats.csv`
  - Example: `local-50_stats.csv`, `local-100_stats.csv`
  
- **AWS EKS tests**: `ks-{param}_stats.csv`
  - Example: `ks-50_stats.csv`, `ks-100_stats.csv`
  - "ks" stands for "Kubernetes" (AWS EKS)

- **Test parameters**: The number (50, 100, etc.) typically represents the test configuration

## Running Analysis

### Option 1: Simple Analysis (No Dependencies)

Run the simple analysis script that only requires pandas:

```bash
# From the test directory
python analyze_results_simple.py
```

This generates:
- `analysis/analysis_summary.csv` - Combined data from all tests
- `analysis/ANALYSIS_REPORT.md` - Detailed markdown report with comparisons

### Option 2: Full Analysis with Plots

Run the full analysis script (requires matplotlib and seaborn):

```bash
# Install dependencies first
pip install pandas matplotlib seaborn

# Run analysis
python analyze_results.py
```

This generates everything from Option 1, plus:
- `analysis/{N}nodes_response_time_comparison.png` - Response time comparison per node count
- `analysis/{N}nodes_throughput_reliability.png` - Throughput and failure rate comparison
- `analysis/scaling_response_time.png` - How response time scales with node count
- `analysis/scaling_throughput.png` - How throughput scales with node count
- `analysis/scaling_failure_rate.png` - How failure rate changes with node count

## Metrics Explained

### Response Time Metrics
- **Median**: 50th percentile - half of requests are faster than this
- **Average**: Mean response time across all requests
- **P95**: 95th percentile - 95% of requests are faster than this
- **P99**: 99th percentile - 99% of requests are faster than this
- **Max**: Slowest request observed

### Performance Metrics
- **Requests/s**: Throughput - how many requests per second the system handled
- **Failure Rate (%)**: Percentage of requests that failed
- **Total Requests**: Total number of requests sent during the test
- **Total Failures**: Number of failed requests

## Interpreting Results

### Good Performance Indicators
- ✓ Low median and average response times (< 100ms is excellent)
- ✓ Low P95 and P99 (indicates consistent performance)
- ✓ High throughput (requests/s)
- ✓ Low failure rate (< 1% is good, < 0.1% is excellent)
- ✓ Small difference between median and P95 (consistent performance)

### Warning Signs
- ⚠ High P99 or Max response times (indicates occasional slowness)
- ⚠ Large gap between median and P95/P99 (inconsistent performance)
- ⚠ High failure rate (> 5%)
- ⚠ Decreasing throughput as load increases

## Example Analysis Output

```
COMPARISON: Local vs AWS EKS (8 nodes)

--- Test Configuration: 50 ---

  Metric                        Local          AWS EKS        Difference
  ----------------------------------------------------------------------
  Total Requests                11130          10921          -209 (-1.9%)
  Failure Rate (%)              8.13           8.06           -0.07 (-0.9%)
  Avg Response Time (ms)        43.49          104.61         +61.12 (+140.6%)
  Median Response Time (ms)     7.00           34.00          +27.00 (+385.7%)
  P95 Response Time (ms)        140.00         120.00         -20.00 (-14.3%)
  Requests/s                    37.72          36.63          -1.09 (-2.9%)

  Interpretation:
    ⚠ AWS EKS is 140.6% slower on average
    ✓ AWS EKS has lower failure rate
```

## Running New Tests

### Local Tests
```bash
# From project root
locust -f test/locustfile.py \
  --host http://localhost:8080 \
  --users 100 \
  --spawn-rate 10 \
  --run-time 10m \
  --headless \
  --csv test/results/8nodes/local-100
```

### AWS EKS Tests
```bash
# Get load balancer URL
$LB_URL = "http://k8s-koordedh-dhtcache-xxx.elb.us-west-2.amazonaws.com"

# Run test
locust -f test/locustfile.py \
  --host $LB_URL \
  --users 100 \
  --spawn-rate 10 \
  --run-time 10m \
  --headless \
  --csv test/results/8nodes/ks-100
```

### Testing Different Node Counts

```bash
# Scale to 16 nodes
kubectl scale statefulset dht-node --replicas=16 -n koorde-dht
kubectl wait --for=condition=ready pod -l app=dht-node -n koorde-dht --timeout=300s

# Run test
locust -f test/locustfile.py --host $LB_URL ... --csv test/results/16nodes/ks-100

# Scale to 32 nodes
kubectl scale statefulset dht-node --replicas=32 -n koorde-dht
kubectl wait --for=condition=ready pod -l app=dht-node -n koorde-dht --timeout=300s

# Run test
locust -f test/locustfile.py --host $LB_URL ... --csv test/results/32nodes/ks-100
```

## Tips for Accurate Testing

1. **Clear cache between tests**: 
   ```bash
   kubectl rollout restart statefulset dht-node -n koorde-dht
   kubectl wait --for=condition=ready pod -l app=dht-node -n koorde-dht --timeout=300s
   ```

2. **Wait for stabilization**: After scaling, wait 1-2 minutes for the DHT to stabilize

3. **Run multiple iterations**: Run each test 2-3 times and compare results

4. **Consistent test parameters**: Use the same `--users`, `--spawn-rate`, and `--run-time` for fair comparison

5. **Monitor during tests**: Watch pod metrics with `kubectl top pods -n koorde-dht`

## Troubleshooting

### No analysis directory created
- Make sure you have pandas installed: `pip install pandas`
- Check that CSV files exist in the results directories

### Plots not generated
- Install plotting libraries: `pip install matplotlib seaborn`
- Use `analyze_results_simple.py` if you don't need plots

### Missing data in comparison
- Ensure both local and AWS tests have been run for the same configuration
- Check that CSV files follow the naming convention (local-* vs ks-*)

## Questions?

For more information about the test setup, see:
- `test/locustfile.py` - Test configuration and workload patterns
- `deploy/eks/README.md` - AWS EKS deployment guide

