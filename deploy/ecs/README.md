# Locust Load Testing on AWS ECS

Deploy Locust load testing infrastructure on AWS ECS with EC2 instances to benchmark Koorde/Chord DHT throughput.

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    ECS Cluster                          │
│  ┌─────────────┐    ┌─────────────┐   ┌─────────────┐  │
│  │   Master    │    │   Worker    │   │   Worker    │  │
│  │  (t3.large) │◄───│  (t3.large) │   │  (t3.large) │  │
│  │  Port 8089  │    │             │   │             │  │
│  │  Port 5557  │    │             │   │             │  │
│  └──────┬──────┘    └──────┬──────┘   └──────┬──────┘  │
│         │                  │                  │         │
└─────────┼──────────────────┼──────────────────┼─────────┘
          │                  │                  │
          └──────────────────┼──────────────────┘
                             │
                             ▼
              ┌──────────────────────────┐
              │   DHT Cluster (EKS)      │
              │  ┌────────┐ ┌────────┐   │
              │  │ Koorde │ │ Chord  │   │
              │  │   LB   │ │   LB   │   │
              │  └────────┘ └────────┘   │
              └──────────────────────────┘
```

## Prerequisites

- AWS CLI configured with credentials
- Docker installed
- EKS cluster with Koorde/Chord deployed
- LabRole IAM role exists in account

## Quick Start

### 1. Deploy Infrastructure

```bash
cd deploy/ecs

# Deploy with 4 worker instances
./deploy-locust.sh --workers 4 --region us-west-2

# Or with SSH access
./deploy-locust.sh --workers 4 --key-name your-key-pair
```

This will:
- Create ECR repository and push Locust image
- Create ECS cluster
- Launch 1 master + 4 worker EC2 instances
- Configure networking and security groups

### 2. Start Load Test

```bash
# Test Koorde
./start-locust.sh http://your-koorde-lb.elb.amazonaws.com --protocol koorde --users 100

# Test Chord  
./start-locust.sh http://your-chord-lb.elb.amazonaws.com --protocol chord --users 100

# With duration limit
./start-locust.sh http://your-lb.elb.amazonaws.com --protocol koorde --users 200 --duration 5m
```

### 3. Access Web UI

Open `http://<master-public-ip>:8089` in your browser.

The master IP is shown after deployment and saved in `locust-config.env`.

### 4. Stop Test

```bash
./stop-locust.sh
```

### 5. Cleanup

```bash
./destroy-locust.sh
```

## Configuration Options

### deploy-locust.sh

| Option | Default | Description |
|--------|---------|-------------|
| `--workers N` | 4 | Number of worker EC2 instances |
| `--region REGION` | us-west-2 | AWS region |
| `--key-name NAME` | (none) | EC2 key pair for SSH access |

### start-locust.sh

| Option | Default | Description |
|--------|---------|-------------|
| `--protocol NAME` | DHT | Protocol name (koorde/chord) |
| `--users N` | 100 | Number of simulated users |
| `--spawn-rate N` | 10 | Users to spawn per second |
| `--duration Xm` | unlimited | Test duration (e.g., 5m, 10m) |
| `--url-pool N` | 100 | Number of unique URLs to test |

## Expected RPS by Worker Count

| Workers | Instance Type | Expected RPS |
|---------|--------------|--------------|
| 1 | t3.large | ~500-800 |
| 2 | t3.large | ~1000-1500 |
| 4 | t3.large | ~2000-3000 |
| 8 | t3.large | ~4000-6000 |

## Cost Estimate

| Resource | Cost/Hour |
|----------|-----------|
| t3.large (per instance) | ~$0.08 |
| 5 instances (1 master + 4 workers) | ~$0.40/hour |
| 1 hour test | ~$0.50 total |

**Tip**: Remember to run `./destroy-locust.sh` after testing!

## Files

| File | Description |
|------|-------------|
| `Dockerfile` | Locust container image |
| `locustfile.py` | Load test script |
| `task-definition-master.json` | ECS task for Locust master |
| `task-definition-worker.json` | ECS task for Locust workers |
| `deploy-locust.sh` | Deploy infrastructure |
| `start-locust.sh` | Start load test |
| `stop-locust.sh` | Stop running test |
| `destroy-locust.sh` | Cleanup all resources |

## Viewing Logs

```bash
# Stream logs in real-time
aws logs tail /ecs/locust-dht --follow --region us-west-2

# View master logs
aws logs tail /ecs/locust-dht --log-stream-name-prefix master --follow

# View worker logs  
aws logs tail /ecs/locust-dht --log-stream-name-prefix worker --follow
```

## Troubleshooting

### No container instances registered

Wait 2-3 minutes after deployment for ECS agents to register.

```bash
# Check registered instances
aws ecs list-container-instances --cluster locust-cluster --region us-west-2
```

### Tasks fail to start

Check task definition and IAM roles:

```bash
# View task failures
aws ecs describe-tasks --cluster locust-cluster --tasks <task-arn> --region us-west-2
```

### Cannot access Web UI

1. Check security group allows port 8089
2. Verify master instance has public IP
3. Check master task is running

```bash
aws ecs list-tasks --cluster locust-cluster --region us-west-2
```

## Example Workflow

```bash
# 1. Deploy infrastructure
./deploy-locust.sh --workers 4

# 2. Wait for ECS agents (2-3 min)
sleep 180

# 3. Test Koorde (5 minutes)
./start-locust.sh http://koorde-lb.amazonaws.com --protocol koorde --users 200 --duration 5m

# 4. Wait for test to complete
sleep 320

# 5. Test Chord (5 minutes)
./start-locust.sh http://chord-lb.amazonaws.com --protocol chord --users 200 --duration 5m

# 6. Wait for test to complete
sleep 320

# 7. Download results from CloudWatch or Web UI

# 8. Cleanup
./destroy-locust.sh
```

