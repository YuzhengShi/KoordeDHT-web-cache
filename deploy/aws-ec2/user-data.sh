#!/bin/bash
set -ex

# Install Docker
yum update -y
yum install -y docker
service docker start
usermod -a -G docker ec2-user

# Get instance metadata
TOKEN=$(curl -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
INSTANCE_ID=$(curl -H "X-aws-ec2-metadata-token: $TOKEN" -v http://169.254.169.254/latest/meta-data/instance-id)
PRIVATE_IP=$(curl -H "X-aws-ec2-metadata-token: $TOKEN" -v http://169.254.169.254/latest/meta-data/local-ipv4)

# Run Koorde Node
docker run -d \
  --name koorde-node \
  --net=host \
  --restart always \
  -e NODE_ID="" \
  -e NODE_HOST="$PRIVATE_IP" \
  -e NODE_BIND="0.0.0.0" \
  -e NODE_PORT="4000" \
  -e CACHE_HTTP_PORT="8080" \
  -e BOOTSTRAP_MODE="${bootstrap_mode}" \
  -e BOOTSTRAP_PEERS="${bootstrap_peers}" \
  -e AWS_REGION="${region}" \
  -e DHT_ID_BITS="66" \
  -e DHT_MODE="private" \
  -e DHT_PROTOCOL="koorde" \
  -e DEBRUIJN_DEGREE="8" \
  -e DEBRUIJN_FIX_INTERVAL="5s" \
  -e SUCCESSOR_LIST_SIZE="8" \
  -e STABILIZATION_INTERVAL="1s" \
  -e FAILURE_TIMEOUT="5s" \
  -e STORAGE_FIX_INTERVAL="20s" \
  flaviosimonelli/koorde-node:latest

# DEBUG: Output logs to console
echo "Started Koorde Node with IP: $PRIVATE_IP"
sleep 10
echo "Docker Logs:"
docker logs koorde-node
