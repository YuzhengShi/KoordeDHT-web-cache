#!/bin/bash
set -euo pipefail

echo "============================================"
echo "  Starting LocalStack Deployment"
echo "============================================"

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

# Get Zone ID (assuming only one zone for simplicity or filtering)
ZONE_ID=$($AWS_CMD route53 list-hosted-zones --query "HostedZones[?Name=='dht.local.'].Id" --output text | cut -d'/' -f3)
echo "Zone ID: $ZONE_ID"

# Update docker-compose environment with real Zone ID? 
# For now, we hardcoded a dummy ID in docker-compose.yml because LocalStack might accept any ID or we need to be dynamic.
# Actually, LocalStack generates a random ID. We should probably pass it to the containers.
# Let's restart containers with the correct ZONE_ID if needed, or just rely on the fact that 
# our code might need the correct ID to register.
# 
# Strategy: Export ZONE_ID and use it in docker-compose if we use env substitution, 
# OR just print it and let the user know. 
# 
# Better approach for automation: 
# We can't easily update the running docker-compose env without restarting.
# Let's stop, export, and start.

echo "[3/4] Starting Koorde Nodes with Zone ID: $ZONE_ID..."
export ROUTE53_ZONE_ID=$ZONE_ID
docker-compose up -d --build koorde-node-0 koorde-node-1 koorde-node-2 nginx-lb

echo "[4/4] Deployment Complete!"
echo ""
echo "Nodes are running on ports:"
echo "  Node 0: HTTP 8080, gRPC 4000"
echo "  Node 1: HTTP 8081, gRPC 4001"
echo "  Node 2: HTTP 8082, gRPC 4002"
echo ""
echo "Verify with:"
echo "  curl http://localhost:8080/health"
echo ""
