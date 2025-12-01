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

echo "============================================"
echo "  Destroying ${PROTOCOL} DHT Deployment"
echo "============================================"
echo "Namespace: ${NAMESPACE}"
echo ""

read -p "Are you sure? This will delete all resources in ${NAMESPACE}. (y/N) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
fi

echo "[1/4] Deleting Services (this will remove load balancers)..."
kubectl delete svc dht-cache-http -n ${NAMESPACE} --ignore-not-found=true
kubectl delete svc dht-grpc -n ${NAMESPACE} --ignore-not-found=true
kubectl delete svc dht-headless -n ${NAMESPACE} --ignore-not-found=true

echo "[2/4] Deleting StatefulSet..."
kubectl delete statefulset dht-node -n ${NAMESPACE} --ignore-not-found=true

echo "[3/4] Deleting ConfigMap..."
kubectl delete configmap dht-config -n ${NAMESPACE} --ignore-not-found=true

echo "[4/4] Deleting Namespace..."
kubectl delete namespace ${NAMESPACE} --ignore-not-found=true

echo ""
echo "============================================"
echo "  Destruction Complete"
echo "============================================"
