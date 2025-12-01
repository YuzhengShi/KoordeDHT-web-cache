#!/bin/bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <chord|koorde>"
    exit 1
fi

PROTOCOL=$1
if [[ "$PROTOCOL" != "chord" && "$PROTOCOL" != "koorde" ]]; then
    echo "Error: Protocol must be 'chord' or 'koorde'"
    exit 1
fi

NAMESPACE="${PROTOCOL}-dht"
REPLICAS="${REPLICAS:-10}"

echo "Deploying ${PROTOCOL} DHT to EKS namespace ${NAMESPACE}..."

# Create namespace
kubectl create namespace ${NAMESPACE} --dry-run=client -o yaml | kubectl apply -f -

# Apply configurations
echo "Applying configmap-${PROTOCOL}.yaml..."
kubectl apply -f configmap-${PROTOCOL}.yaml -n ${NAMESPACE}

# Apply protocol-specific resources
if [[ "$PROTOCOL" == "chord" ]]; then
    echo "Applying Chord-specific ConfigMap and StatefulSet..."
    kubectl apply -f chord-entrypoint-configmap.yaml -n ${NAMESPACE}
    kubectl apply -f chord-statefulset.yaml -n ${NAMESPACE}
elif [[ "$PROTOCOL" == "koorde" ]]; then
    echo "Applying Koorde-specific StatefulSet..."
    kubectl apply -f statefulset-koorde.yaml -n ${NAMESPACE}
fi

# Scale replicas
echo "Scaling to ${REPLICAS} replicas..."
kubectl scale statefulset dht-node --replicas=${REPLICAS} -n ${NAMESPACE}

# Apply services
echo "Applying services..."
kubectl apply -f service-headless.yaml -n ${NAMESPACE}
kubectl apply -f service-cache.yaml -n ${NAMESPACE}
kubectl apply -f service-grpc.yaml -n ${NAMESPACE}

# Wait for rollout
echo "Waiting for pods to be ready..."
kubectl rollout status statefulset/dht-node -n ${NAMESPACE} --timeout=5m

# Wait for load balancer
echo "Waiting for load balancer..."
kubectl wait --for=condition=ready \
  service/dht-cache-http \
  -n ${NAMESPACE} \
  --timeout=5m

# Get load balancer URL
LB_URL=$(kubectl get svc dht-cache-http -n ${NAMESPACE} \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

echo ""
echo "Deployment complete!"
echo "Protocol: ${PROTOCOL}"
echo "Namespace: ${NAMESPACE}"
echo "HTTP Cache URL: http://${LB_URL}"
echo ""
echo "Test with:"
echo "  curl \"http://${LB_URL}/cache?url=https://httpbin.org/json\""
echo "  curl \"http://${LB_URL}/metrics\" | jq"
