# LocalStack Deployment

This directory contains scripts to deploy the KoordeDHT cluster to a local environment using [LocalStack](https://localstack.cloud/) to simulate AWS Route53.

## Prerequisites

- Docker and Docker Compose
- AWS CLI (v2 recommended)
- `awslocal` (optional, wrapper for AWS CLI)
- `jq` (optional, for JSON processing)

## Usage

1.  **Start the environment:**
    
    **On Linux/Mac:**
    ```bash
    chmod +x start.sh
    ./start.sh
    ```
    
    **On Windows (PowerShell):**
    ```powershell
    .\start.ps1
    ```
    
    This script will:
    - Start LocalStack.
    - Create a Route53 hosted zone `dht.local`.
    - Start 3 Koorde nodes configured to use LocalStack for discovery.

2.  **Verify:**
    
    **Via Load Balancer (recommended for fair comparison with AWS):**
    ```bash
    curl http://localhost:9000/health
    curl http://localhost:9000/cache?url=https://httpbin.org/json
    ```
    
    **Direct to nodes (for debugging):**
    ```bash
    curl http://localhost:8080/health  # Node 0
    curl http://localhost:8081/health  # Node 1
    curl http://localhost:8082/health  # Node 2
    ```

3.  **Stop:**
    ```bash
    docker-compose down
    ```

## Configuration

The `docker-compose.yml` defines the node configuration. Key environment variables:
- `BOOTSTRAP_MODE=route53`: Enables Route53 discovery.
- `ROUTE53_ENDPOINT=http://localstack:4566`: Points to LocalStack.
- `ROUTE53_ZONE_ID`: Injected by `start.sh`.
