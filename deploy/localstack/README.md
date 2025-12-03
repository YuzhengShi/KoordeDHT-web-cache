# LocalStack Deployment (Local AWS-like Environment)

This directory contains everything needed to run **KoordeDHT-Web-Cache** in a **local, AWS-like environment** using [LocalStack](https://localstack.cloud/).
It mirrors the **AWS EKS architecture** described in `deploy/eks/README.md`, but runs entirely on your machine via Docker.

- For full architecture details and production-focused docs, see:  
  `deploy/eks/README.md` (AWS EKS Deployment with Load Balancer).

---

## Architecture Overview

Conceptually, this LocalStack setup matches the EKS architecture:

- **LocalStack (Route53 emulation)**: simulates AWS Route53 for name-based bootstrap/discovery.
- **DHT nodes (Docker containers)**: run the Koorde or Chord node binary.
- **Local HTTP entrypoint / load balancer**: Nginx on your machine:
  - Exposes a single HTTP endpoint on `http://localhost:9000`.
  - Proxies requests to the DHT nodes' `/cache`, `/metrics`, `/health` endpoints.

This lets you:

- Develop and debug locally against an AWS-like control-plane (Route53) without real AWS.
- Run **Locust** or other load tests against `http://localhost:9000`.
- **Compare Koorde vs Chord** performance by running experiments with each protocol.

For the true EKS deployment (Kubernetes, NLB/ALB, HPA, etc.), use `deploy/eks/README.md`.

---

## Prerequisites

- Docker and Docker Compose
- AWS CLI (v2 recommended)
- `awslocal` (optional, wrapper for AWS CLI)
- `jq` (optional, for JSON processing)
- PowerShell (for Windows; also works on Linux/Mac via `pwsh`)

> You do **not** need a real AWS account for this setup – LocalStack runs everything locally.

---

## Quick Start

### Start a Koorde Cluster (Default)

**On Windows (PowerShell):**

```powershell
cd deploy\localstack
.\start.ps1
```

**On Linux/Mac:**

```bash
cd deploy/localstack
chmod +x start.sh
./start.sh
```

### Start a Chord Cluster

**On Windows (PowerShell):**

```powershell
.\start.ps1 -Protocol chord
```

**On Linux/Mac:**

```bash
./start.sh chord
```

---

## Protocol Comparison Experiments

You can run sequential experiments comparing **Koorde** and **Chord** performance:

### Step 1: Run Koorde Experiment

```powershell
# Start Koorde cluster
.\start.ps1 -Protocol koorde -Nodes 16 -Degree 4

# Run your benchmark/load test
# e.g., locust -f test/locustfile.py --host=http://localhost:9000

# Collect results...

# Stop the cluster
docker-compose down
```

### Step 2: Run Chord Experiment

```powershell
# Start Chord cluster (same number of nodes for fair comparison)
.\start.ps1 -Protocol chord -Nodes 16 -Degree 4

# Run the same benchmark/load test
# e.g., locust -f test/locustfile.py --host=http://localhost:9000

# Collect results...

# Stop the cluster
docker-compose down
```

### Parameters

| Parameter | PowerShell | Bash | Default | Description |
|-----------|------------|------|---------|-------------|
| Protocol | `-Protocol` | 1st arg | `koorde` | DHT protocol: `koorde` or `chord` |
| Nodes | `-Nodes` | 2nd arg | `16` | Number of DHT nodes |
| Degree | `-Degree` | 3rd arg | `4` | De Bruijn degree (for Koorde) |

**Examples:**

```powershell
# PowerShell: 8 Koorde nodes with degree 2
.\start.ps1 -Protocol koorde -Nodes 8 -Degree 2

# PowerShell: 32 Chord nodes
.\start.ps1 -Protocol chord -Nodes 32
```

```bash
# Bash: 8 Koorde nodes with degree 2
./start.sh koorde 8 2

# Bash: 32 Chord nodes
./start.sh chord 32
```

---

## Verify Deployment

**Via the HTTP entrypoint (recommended):**

```bash
# Cache request
curl "http://localhost:9000/cache?url=https://httpbin.org/json"

# Metrics
curl "http://localhost:9000/metrics"

# Health
curl "http://localhost:9000/health"
```

**Directly against individual nodes (debugging only):**

```bash
curl http://localhost:8080/health  # Node 0
curl http://localhost:8081/health  # Node 1
curl http://localhost:8082/health  # Node 2
```

---

## Stop the Environment

From `deploy/localstack`:

```bash
docker-compose down
```

To clean up volumes as well:

```bash
docker-compose down -v
```

---

## Configuration Overview

### Generated Files

The `generate-docker-compose.ps1` script creates:

- **`docker-compose.yml`**: Defines all services (LocalStack, nginx, DHT nodes)
- **`nginx.conf`**: Load balancer configuration

### Key Environment Variables

Each DHT node receives:

| Variable | Description |
|----------|-------------|
| `DHT_PROTOCOL` | `koorde` or `chord` - selects the DHT implementation |
| `NODE_ID` | Unique hex identifier for the node |
| `NODE_HOST` | Container hostname (e.g., `koorde-node-0`) |
| `NODE_PORT` | gRPC port (4000, 4001, ...) |
| `CACHE_HTTP_PORT` | HTTP port (8080, 8081, ...) |
| `BOOTSTRAP_MODE` | `route53` - uses LocalStack Route53 for discovery |
| `ROUTE53_ENDPOINT` | `http://localstack:4566` - LocalStack endpoint |
| `DEBRUIJN_DEGREE` | De Bruijn graph degree (Koorde-specific) |

### Manual Configuration Generation

You can regenerate configuration without starting:

```powershell
# Generate for Chord with 8 nodes
.\generate-docker-compose.ps1 -Protocol chord -Nodes 8 -Degree 2
```

> For detailed description of DHT internals (routing, cache behavior, metrics), see the main project README and `deploy/eks/README.md`.
