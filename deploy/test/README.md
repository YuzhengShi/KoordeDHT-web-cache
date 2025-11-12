# Automated Testing Deployment (Churn Simulation & Network Chaos)

This deployment configuration enables testing the DHT and web cache behavior under **realistic network conditions** with **dynamic churn** (random node joins and departures).

The system is fully automated and can run both locally and on **AWS EC2 instances**.

## What's Included

- **Automatic docker-compose generation** with simulation parameters
- **Churn controller** (`churn.sh`) to randomly stop and restart nodes
- **Pumba container** for network simulation (latency, jitter, packet loss)
- **Automated tester** that sends lookup requests and collects CSV metrics
- **Orchestration script** (`init.sh`) coordinating the entire simulation
- **CloudFormation template** and AWS launcher for cloud deployment

---

## Prerequisites

### For AWS Deployment
- **S3 bucket** to upload scripts and configuration files
- **AWS CLI** installed and configured with credentials
- **VPC** with at least one subnet for the EC2 instance

### For Local Testing
- **Docker** and **Docker Compose** installed
- At least 8GB RAM (for running multiple nodes)

---

## Quick Start (Local)

### 1. Generate docker-compose File

```bash
cd scripts

./gen_compose.sh \
  --sim-duration 60s \
  --query-rate 0.5 \
  --query-parallelism-min 1 \
  --query-parallelism-max 5 \
  --query-timeout 10s \
  --docker-suffix test
```

This creates `docker-compose.generated.yml` with your parameters.

### 2. Start Containers

```bash
docker-compose -f docker-compose.generated.yml up -d
```

### 3. Run Churn Simulation (Optional)

```bash
./churn.sh apply -p koorde-node- -i 20 -m 3 -j 0.4 -l 0.3
```

**Parameters**:
- `-p`: Container prefix (e.g., `koorde-node-`)
- `-i`: Interval in seconds between events
- `-m`: Minimum number of active nodes to maintain
- `-j`: Join probability (0-1)
- `-l`: Leave probability (0-1)

**Example**: With `-j 0.4 -l 0.3`:
- 40% chance a stopped node restarts
- 30% chance a running node stops
- 30% chance nothing happens
- Always maintains at least `-m` nodes

The script continues until:
- Manually interrupted (Ctrl+C)
- Process is killed (used by `init.sh`)
- `./churn.sh clear` command is executed

### 4. Stop Churn

```bash
./churn.sh clear
```

### 5. View Results

```bash
# Results are in the results directory
cat results/output.csv

# View logs
docker-compose logs -f
```

---

## Network Simulation with Pumba

The **Pumba** container introduces network delays, jitter, and packet loss between nodes.

Pumba is automatically started by `init.sh` and applies network rules to Koorde node containers.

**Example manual usage**:

```bash
# Add 100ms delay with 50ms jitter to all nodes
docker run -it --rm \
  -v /var/run/docker.sock:/var/run/docker.sock \
  gaiaadm/pumba \
  netem --duration 5m \
  delay --time 100 --jitter 50 \
  re2:koorde-node-.*
```

---

## Orchestration Script (init.sh)

The `init.sh` script coordinates the entire simulation:

1. Downloads scripts from S3 (if on AWS)
2. Installs Docker and Docker Compose via `install_docker.sh`
3. Generates `docker-compose.generated.yml` with specified parameters
4. Starts containers with Docker Compose
5. Starts node churn simulation
6. Starts Pumba for network simulation
7. Waits for simulation completion
8. Saves logs and results to S3 (timestamp-named folder)

### Usage

```bash
./init.sh \
  --bucket koorde-bucket \
  --prefix test \
  --sim-duration 5m \
  --query-rate 0.5 \
  --parallel-min 1 \
  --parallel-max 5 \
  --delay 200ms \
  --jitter 50ms \
  --loss 0.1% \
  --churn-interval 20 \
  --churn-min-active 3 \
  --churn-pjoin 0.4 \
  --churn-pleave 0.3 \
  --max-nodes 10
```

**Parameters**:

| Parameter | Description | Example |
|-----------|-------------|---------|
| `--bucket` | S3 bucket name | `koorde-bucket` |
| `--prefix` | S3 prefix/folder | `test` |
| `--sim-duration` | Total simulation time | `5m`, `300s` |
| `--query-rate` | Queries per second | `0.5`, `10` |
| `--parallel-min/max` | Worker threads | `1`, `5` |
| `--delay` | Network latency | `100ms` |
| `--jitter` | Latency variance | `50ms` |
| `--loss` | Packet loss rate | `0.1%` |
| `--churn-interval` | Seconds between churn events | `20` |
| `--churn-min-active` | Minimum live nodes | `3` |
| `--churn-pjoin` | Join probability | `0.4` |
| `--churn-pleave` | Leave probability | `0.3` |
| `--max-nodes` | Maximum nodes in cluster | `10` |

---

## AWS Deployment

### Setup

1. **Upload scripts to S3**:

```bash
aws s3 sync scripts/ s3://koorde-bucket/test/
```

2. **Ensure AWS prerequisites**:
- VPC with subnet
- IAM role for Route53 access
- EC2 key pair for SSH access
- AWS credentials in `~/.aws/credentials`

### Deploy

```bash
./deploy_test.sh \
  --keypair Amazon-Key \
  --s3-bucket koorde-bucket \
  --s3-prefix test \
  --vpc-id vpc-0123456789abcdef \
  --subnet-id subnet-0123456789abcdef \
  --instance-type t2.small \
  --sim-duration 5m \
  --query-rate 0.8 \
  --parallel-min 1 \
  --parallel-max 5 \
  --delay 100ms \
  --jitter 50ms \
  --loss 0.1% \
  --churn-interval 15 \
  --churn-min-active 5 \
  --churn-pjoin 0.5 \
  --churn-pleave 0.5 \
  --max-nodes 30
```

This launches the CloudFormation stack `test_koorde.yml` with your parameters.

### Monitor

Monitor EC2 instance via AWS Console and SSH for real-time logs:

```bash
ssh -i ~/.ssh/Amazon-Key.pem ec2-user@<EC2_IP>

# View logs
tail -f /var/log/test/*.log

# View results
cat results/output.csv
```

### Results Location

- **Local logs**: `/var/log/test/`
- **CSV results**: `./results/output.csv`
- **AWS S3**: `s3://<bucket>/<prefix>/results/<timestamp>/`

### Teardown

```bash
./destroy_test.sh
```

This deletes the CloudFormation stack and terminates all associated EC2 instances.

---

## Understanding the Test Configuration

### What's Being Tested

1. **DHT Lookup Performance**
   - Lookup latency under various network conditions
   - Impact of churn on routing correctness
   - Fault tolerance with successor lists

2. **Web Cache Behavior**
   - Cache hit rates with realistic workloads
   - Hotspot detection accuracy
   - Load distribution effectiveness

3. **Network Resilience**
   - Performance under latency/jitter
   - Recovery from packet loss
   - Handling of node failures

### Test Scenarios

**Scenario 1: Low Latency, Low Churn**
```bash
--delay 50ms --jitter 20ms --churn-interval 30 --churn-pleave 0.3
```
Expected: High hit rates, stable routing

**Scenario 2: High Latency, High Churn**
```bash
--delay 200ms --jitter 100ms --churn-interval 10 --churn-pleave 0.5
```
Expected: Increased latency, more cache misses, routing overhead

**Scenario 3: Packet Loss**
```bash
--delay 100ms --loss 5% --churn-interval 20
```
Expected: Timeout handling, retry mechanisms

---

## Analyzing Results

### CSV Output Format

```csv
timestamp,node,result,delay_ms
2025-10-07T14:21:49.628964397Z,koorde-node-28:4000,SUCCESS,16.000
2025-10-07T14:21:49.631869517Z,koorde-node-27:4000,SUCCESS,19.000
```

### Key Metrics

```bash
# Average latency
awk -F',' '{sum+=$4; count++} END {print sum/count}' results/output.csv

# Success rate
grep -c SUCCESS results/output.csv

# Failed lookups
grep -c FAIL results/output.csv
```

### Visualize with Python

```python
import pandas as pd
import matplotlib.pyplot as plt

df = pd.read_csv('results/output.csv')
df['delay_ms'].hist(bins=50)
plt.xlabel('Latency (ms)')
plt.ylabel('Frequency')
plt.title('DHT Lookup Latency Distribution')
plt.show()
```

---

## Example Results

See `results/` directory for example outputs from previous runs:

- `output_20251007_*.csv` - Lookup latency data
- `output_20251007_*.log` - Full simulation logs

**Typical results** (30 nodes, delay=100ms, churn=15s):
- **Avg latency**: 150-200ms
- **Success rate**: >99%
- **Lookup hops**: 3-5 (with degree=8)

---

## CloudFormation Template

The `test_koorde.yml` template creates:
- EC2 instance with Docker pre-installed
- Security group allowing inbound gRPC (4000+) and HTTP (8080)
- IAM role for Route53 access
- User data script that downloads and runs `init.sh`

### Stack Outputs

After deployment, CloudFormation outputs:
- **InstanceId**: EC2 instance ID
- **PublicIP**: Public IP address for SSH access
- **PrivateIP**: Private IP for VPC-internal communication

---

## Troubleshooting

**Issue: Nodes not stabilizing**
```bash
# Check if enough nodes are running
docker ps | grep koorde-node

# Verify churn isn't too aggressive
# Reduce --churn-pleave or increase --churn-min-active
```

**Issue: High lookup failures**
```bash
# Check network delay isn't too high
docker-compose logs pumba

# Increase query timeout
--query-timeout 30s
```

**Issue: Out of memory**
```bash
# Reduce number of nodes
--max-nodes 5

# Or use larger instance type
--instance-type t2.medium
```

**Issue: Churn script not working**
```bash
# Check container prefix matches
docker ps --format '{{.Names}}' | grep koorde-node

# Verify Docker socket is accessible
ls -la /var/run/docker.sock
```

---

## Advanced Usage

### Custom Test Scenarios

Create custom test scenarios by modifying parameters:

```bash
# Long-running stability test
./deploy_test.sh --sim-duration 1h --churn-interval 60

# High-throughput test
./deploy_test.sh --query-rate 50 --parallel-max 20

# Extreme churn
./deploy_test.sh --churn-interval 5 --churn-pleave 0.7
```

### Manual Testing

```bash
# Start cluster without automation
docker-compose -f docker-compose.generated.yml up -d

# Manually control churn
docker stop koorde-node-5
sleep 30
docker start koorde-node-5

# Run custom queries
docker exec koorde-tester /usr/local/bin/koorde-tester --config /config.yaml
```

---

## Notes

- Example results are available in `results/` directory
- All scripts are in `scripts/` subdirectory
- CloudFormation template is `test_koorde.yml`
- Logs are saved to `/var/log/test/` on EC2
- Results are uploaded to S3 after completion (AWS only)

---

## Next Steps

- Try [local deployment](../tracing/README.md) for development
- Scale to [production AWS](../demonstration/README.md) for multi-instance testing
- Analyze results with visualization tools
- Tune parameters for your use case
