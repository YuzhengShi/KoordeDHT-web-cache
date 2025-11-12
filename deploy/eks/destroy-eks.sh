#!/bin/bash
set -euo pipefail

NAMESPACE="${NAMESPACE:-koorde-cache}"

echo "============================================"
echo "  Destroying KoordeDHT-Web-Cache Deployment"
echo "============================================"
echo "Namespace: ${NAMESPACE}"
echo ""

read -p "Are you sure? This will delete all resources. (y/N) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
fi

echo "[1/4] Deleting Services (this will remove load balancers)..."
kubectl delete svc koorde-cache-http -n ${NAMESPACE} --ignore-not-found=true
kubectl delete svc koorde-grpc -n ${NAMESPACE} --ignore-not-found=true
kubectl delete svc koorde-headless -n ${NAMESPACE} --ignore-not-found=true

echo "[2/4] Deleting StatefulSet..."
kubectl delete statefulset koorde-node -n ${NAMESPACE} --ignore-not-found=true

echo "[3/4] Deleting ConfigMap..."
kubectl delete configmap koorde-config -n ${NAMESPACE} --ignore-not-found=true

echo "[4/4] Deleting Namespace..."
kubectl delete namespace ${NAMESPACE} --ignore-not-found=true

echo ""
echo "============================================"
echo "  Destruction Complete"
echo "============================================"

