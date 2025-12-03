#!/bin/bash
set -euo pipefail

# Parse arguments
PROTOCOL="${1:-koorde}"
NODES="${2:-16}"
DEGREE="${3:-4}"

# Validate protocol
if [[ "$PROTOCOL" != "koorde" && "$PROTOCOL" != "chord" ]]; then
    echo "Error: Protocol must be 'koorde' or 'chord'"
    echo "Usage: $0 [protocol] [nodes] [degree]"
    echo "  protocol: koorde (default) or chord"
    echo "  nodes: number of nodes (default: 16)"
    echo "  degree: de Bruijn degree (default: 4)"
    exit 1
fi

echo "============================================"
echo "  Starting LocalStack Deployment ($PROTOCOL)"
echo "============================================"

# Generate docker-compose.yml and nginx.conf for the selected protocol
echo "[0/4] Generating configuration for $PROTOCOL..."
pwsh -File "$(dirname "$0")/generate-docker-compose.ps1" -Protocol "$PROTOCOL" -Nodes "$NODES" -Degree "$DEGREE" 2>/dev/null || \
    powershell.exe -File "$(dirname "$0")/generate-docker-compose.ps1" -Protocol "$PROTOCOL" -Nodes "$NODES" -Degree "$DEGREE" 2>/dev/null || \
    echo "Warning: PowerShell not available, using existing docker-compose.yml"

# Check for awslocal or aws
if command -v awslocal &> /dev/null; then
    AWS_CMD="awslocal"
else
    echo "awslocal not found, using 'aws --endpoint-url=http://localhost:4566'"
    AWS_CMD="aws --endpoint-url=http://localhost:4566"
fi

echo "[1/4] Starting LocalStack..."
docker-compose up -d localstack

echo "Waiting for LocalStack to be ready..."
until $AWS_CMD route53 list-hosted-zones &> /dev/null; do
    echo -n "."
    sleep 2
done
echo " Ready!"

echo "[2/4] Creating Route53 Hosted Zone..."
# Create hosted zone if it doesn't exist
if ! $AWS_CMD route53 list-hosted-zones | grep -q "dht.local"; then
    $AWS_CMD route53 create-hosted-zone --name dht.local --caller-reference $(date +%s)
    echo "Created hosted zone: dht.local"
else
    echo "Hosted zone dht.local already exists"
fi

# Get Zone ID
ZONE_ID=$($AWS_CMD route53 list-hosted-zones --query "HostedZones[?Name=='dht.local.'].Id" --output text | cut -d'/' -f3)
echo "Zone ID: $ZONE_ID"

echo "[3/4] Starting $PROTOCOL nodes with Zone ID: $ZONE_ID..."
export ROUTE53_ZONE_ID=$ZONE_ID
docker-compose up -d --build

echo "[4/4] Deployment Complete!"
echo ""
echo "Protocol: $PROTOCOL"
echo "Nodes: $NODES"
echo ""
echo "Load Balancer:"
echo "  http://localhost:9000 (nginx - distributes across all nodes)"
echo ""
echo "Individual Nodes:"
echo "  Node 0: HTTP 8080, gRPC 4000"
echo "  Node 1: HTTP 8081, gRPC 4001"
echo "  Node 2: HTTP 8082, gRPC 4002"
echo "  ..."
echo ""
echo "Verify with:"
echo "  curl http://localhost:9000/health  # Via load balancer"
echo "  curl http://localhost:8080/health  # Direct to node 0"
echo ""
echo "To switch protocols:"
echo "  docker-compose down"
echo "  ./start.sh chord  # or koorde"
echo ""
