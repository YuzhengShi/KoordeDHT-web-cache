# Locust Load Testing Plan for Koorde Web Cache

## Overview

This testing plan uses Locust to compare latency between LocalStack and AWS deployments of the Koorde distributed web cache.

## Prerequisites

### Install Locust
```powershell
pip install locust
```

### Verify Installation
```powershell
locust --version
```

## Test Scenarios

### Scenario 1: LocalStack Baseline Test

**Purpose**: Establish baseline performance metrics for local deployment.

**Configuration**:
- **Target**: `http://localhost:9000` (nginx load balancer)
- **Users**: 50 concurrent users
- **Spawn Rate**: 5 users/second
- **Duration**: 5 minutes
- **URL Pool**: 300 unique URLs
- **Distribution**: Zipf (α=1.2) - realistic skewed access pattern

**Command**:
```powershell
cd test
locust -f locustfile.py `
  --host http://localhost:9000 `
  --users 50 `
  --spawn-rate 5 `
  --run-time 5m `
  --headless `
  --csv results/localstack_baseline
```

**Expected Metrics**:
- Average latency: 5-15ms (localhost)
- Hit rate: 60-80% (after warm-up)
- Throughput: ~500-1000 req/s

---

### Scenario 2: AWS Production Test

**Purpose**: Measure production performance with real network latency.

**Configuration**:
- **Target**: `http://<AWS-ALB-DNS>` (AWS Application Load Balancer)
- **Users**: 50 concurrent users
- **Spawn Rate**: 5 users/second
- **Duration**: 5 minutes
- **URL Pool**: 300 unique URLs (same as LocalStack)
- **Distribution**: Zipf (α=1.2)

**Command**:
```powershell
cd test
locust -f locustfile.py `
  --host http://<AWS-ALB-DNS> `
  --users 50 `
  --spawn-rate 5 `
  --run-time 5m `
  --headless `
  --csv results/aws_production
```

**Expected Metrics**:
- Average latency: 50-150ms (network + processing)
- Hit rate: 60-80% (similar to LocalStack)
- Throughput: ~200-500 req/s (network limited)

---

### Scenario 3: Stress Test (LocalStack)

**Purpose**: Find performance limits of the local deployment.

**Configuration**:
- **Target**: `http://localhost:9000`
- **Users**: Start at 10, ramp up to 200
- **Spawn Rate**: 10 users/second
- **Duration**: 10 minutes

**Command**:
```powershell
cd test
locust -f locustfile.py `
  --host http://localhost:9000 `
  --users 200 `
  --spawn-rate 10 `
  --run-time 10m `
  --headless `
  --csv results/localstack_stress
```

---

### Scenario 4: Sustained Load Test (AWS)

**Purpose**: Verify AWS deployment stability under sustained load.

**Configuration**:
- **Target**: `http://<AWS-ALB-DNS>`
- **Users**: 100 concurrent users
- **Spawn Rate**: 5 users/second
- **Duration**: 30 minutes

**Command**:
```powershell
cd test
locust -f locustfile.py `
  --host http://<AWS-ALB-DNS> `
  --users 100 `
  --spawn-rate 5 `
  --run-time 30m `
  --headless `
  --csv results/aws_sustained
```

---

## Interactive Mode (Web UI)

For real-time monitoring and manual control:

```powershell
# LocalStack
locust -f locustfile.py --host http://localhost:9000

# AWS
locust -f locustfile.py --host http://<AWS-ALB-DNS>
```

Then open: `http://localhost:8089`

---

## Results Analysis

### CSV Output Files

  --localstack results/localstack_baseline_stats.csv `
  --aws results/aws_production_stats.csv `
  --output comparison_report.md
```

---

## Test Variations

### High Cache Hit Rate Test

Modify `locustfile.py` to use smaller URL pool (e.g., 50 URLs):
```python
URL_POOL_SIZE = 50  # More cache hits
```

### Cold Cache Test

Modify task weights to favor random access:
```python
@task(1)  # Reduce Zipf weight
def cache_request_zipf(self):
    ...

@task(10)  # Increase random weight
def cache_request_random(self):
    ...
```

### Single Node Test

Test direct node access (bypass load balancer):
```powershell
locust -f locustfile.py --host http://localhost:8080
```

---

## Distributed Load Testing

For higher load, run Locust in distributed mode:

### Master Node
```powershell
locust -f locustfile.py --master --expect-workers 3
```

### Worker Nodes (run 3 times)
```powershell
locust -f locustfile.py --worker --master-host localhost
```

---

## Monitoring During Tests

### LocalStack
```powershell
# Watch container stats
docker stats

# Watch logs
docker-compose logs -f koorde-node-0

# Check metrics
curl http://localhost:9000/metrics
```

### AWS
```powershell
# CloudWatch metrics
aws cloudwatch get-metric-statistics ...

# EKS pod logs
kubectl logs -f koorde-node-0

# ALB metrics
aws elbv2 describe-target-health ...
```

---

## Expected Outcomes

### Latency Comparison

**LocalStack (localhost)**:
- Network latency: ~0-1ms
- DHT routing: ~2-5ms
- Cache retrieval: ~1-3ms
- **Total: ~5-10ms**

**AWS (internet)**:
- Network latency: ~20-50ms (varies by location)
- Load balancer: ~5-10ms
- DHT routing: ~2-5ms
- Cache retrieval: ~1-3ms
- **Total: ~30-70ms**

### Key Insights

1. **Network overhead dominates** in AWS deployment (60-80% of latency)
2. **DHT routing efficiency** is similar in both environments
3. **Cache hit rate** should be identical (same workload pattern)
4. **LocalStack is suitable** for functional testing, not performance benchmarking
5. **AWS results reflect** real-world production latency

---

## Troubleshooting

### High Failure Rate
- Check if deployment is healthy: `curl http://localhost:9000/health`
- Reduce spawn rate or user count
- Check Docker/AWS resource limits

### Low Hit Rate
- Increase test duration (allow cache warm-up)
- Reduce URL pool size
- Check cache capacity settings

### Inconsistent Latency
- AWS: Normal due to network variability
- LocalStack: Check Docker resource allocation
- Consider running multiple test iterations

---

## Next Steps

After completing tests:

1. **Generate comparison report**
2. **Analyze latency percentiles** (P50, P95, P99)
3. **Identify bottlenecks** (network vs. DHT vs. cache)
4. **Optimize configuration** based on findings
5. **Document results** in experiment report
