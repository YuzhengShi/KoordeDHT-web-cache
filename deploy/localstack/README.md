# LocalStack Deployment (Local AWS-like Environment)

This directory contains everything needed to run **KoordeDHT-Web-Cache** in a **local, AWS-like environment** using [LocalStack](https://localstack.cloud/).
It mirrors the **AWS EKS architecture** described in `deploy/eks/README.md`, but runs entirely on your machine via Docker.

- For full architecture details and production-focused docs, see:  
  `deploy/eks/README.md` (AWS EKS Deployment with Load Balancer).

---

## Architecture Overview

┌─────────────────────────────────────────────────────────────────┐
│                     Local Machine (Docker)                       │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│   ┌────────────────┐                                             │
│   │   LocalStack   │  ← Emulates Route53 (port 4566)             │
│   │   (Route53)    │    DNS-based node discovery                 │
│   └───────┬────────┘                                             │
│           │ Node registration & discovery                        │
│           ▼                                                      │
│   ┌───────────────────────────────────────────────────────┐      │
│   │              Koorde DHT Nodes (16 nodes)              │      │
│   │  ┌──────┐ ┌──────┐ ┌──────┐     ┌───────┐             │      │
│   │  │Node-0│ │Node-1│ │Node-2│ ... │Node-15│             │      │
│   │  │:8080 │ │:8081 │ │:8082 │     │:8095  │             │      │
│   │  └──────┘ └──────┘ └──────┘     └───────┘             │      │
│   └───────────────────────────────────────────────────────┘      │
│           ▲                                                      │
│           │ Load balanced                                        │
│   ┌───────┴────────┐                                             │
│   │   Nginx LB     │  ← http://localhost:9000                    │
│   │   (port 9000)  │    (like AWS NLB in production)             │
│   └────────────────┘                                             │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘

Conceptually, this LocalStack setup matches the EKS architecture:

- **LocalStack (Route53 emulation)**: simulates AWS Route53 for name-based bootstrap/discovery.
- **Koorde nodes (Docker containers)**: run the same Koorde node binary used in EKS.
- **Local HTTP entrypoint / load balancer**: Nginx (or a simple HTTP frontend) on your machine:
  - Exposes a single HTTP endpoint on `http://localhost:9000`.
  - Proxies requests to the Koorde nodes’ `/cache`, `/metrics`, `/health` endpoints.

This lets you:

- Develop and debug Koorde locally against an AWS-like control-plane (Route53) without real AWS.
- Run **Locust** or other load tests against `http://localhost:9000` and compare directly with the EKS load balancer URL.

For the true EKS deployment (Kubernetes, NLB/ALB, HPA, etc.), use `deploy/eks/README.md`.

---

## Prerequisites

- Docker and Docker Compose
- AWS CLI (v2 recommended)
- `awslocal` (optional, wrapper for AWS CLI)
- `jq` (optional, for JSON processing)

> You do **not** need a real AWS account for this setup – LocalStack runs everything locally.

---

## How to Start LocalStack Koorde Cluster

1. **Start the environment**

   **On Linux/Mac:**

   ```bash
   cd deploy/localstack
   chmod +x start.sh
   ./start.sh
   ```

   **On Windows (PowerShell):**

   ```powershell
   cd deploy\localstack
   .\start.ps1
   ```

   The start script will:

   - Start LocalStack with `docker-compose.yml`.
   - Create a Route53 hosted zone (e.g., `dht.local`) inside LocalStack.
   - Inject the hosted zone ID into the Koorde containers.
   - Start **3 Koorde nodes** configured to use LocalStack for bootstrap/discovery.
   - Start the local HTTP entrypoint (Nginx) on `http://localhost:9000`.

2. **Verify the deployment**

   **Via the HTTP entrypoint (recommended for fair comparison with AWS EKS):**

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

3. **Stop the environment**

   From `deploy/localstack`:

   ```bash
   docker-compose down
   ```

---

## Configuration Overview

The core of this setup is `docker-compose.yml` and `nginx.conf`:

- **`docker-compose.yml`**:

  - Defines:
    - `localstack` container (simulated AWS services, especially Route53).
    - Multiple `koorde-node-*` containers running the Koorde binary.
    - An `nginx` container exposing `http://localhost:9000` and proxying to the nodes.
  - Important environment variables for the nodes:
    - `BOOTSTRAP_MODE=route53`: enables Route53-based bootstrap (mirrors EKS Route53 mode).
    - `ROUTE53_ENDPOINT=http://localstack:4566`: points to LocalStack instead of real AWS.
    - `ROUTE53_ZONE_ID`: injected by `start.sh` / `start.ps1` after creating the hosted zone.

- **`nginx.conf`**:
  - Defines how Nginx balances requests across Koorde HTTP endpoints.
  - Provides a single, stable URL (`http://localhost:9000`) similar to the EKS NLB DNS name.

> For detailed description of Koorde internals (DHT routing, cache behavior, metrics), see the main project README and `deploy/eks/README.md`.
