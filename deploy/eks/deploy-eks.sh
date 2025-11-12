#!/bin/bash
set -euo pipefail

# Configuration
NAMESPACE="${NAMESPACE:-koorde-cache}"
REPLICAS="${REPLICAS:-10}"
CLUSTER_NAME="${CLUSTER_NAME:-koorde-cache}"
REGION="${REGION:-us-east-1}"

echo "============================================"
echo "  KoordeDHT-Web-Cache EKS Deployment"
echo "============================================"
echo "Cluster: ${CLUSTER_NAME}"
echo "Region: ${REGION}"
echo "Namespace: ${NAMESPACE}"
echo "Replicas: ${REPLICAS}"
echo "============================================"
echo ""

# Check if kubectl is configured
if ! kubectl cluster-info &>/dev/null; then
    echo "Error: kubectl not configured. Run:"
    echo "  aws eks update-kubeconfig --name ${CLUSTER_NAME} --region ${REGION}"
    exit 1
fi

# Check if AWS Load Balancer Controller is installed
if ! kubectl get deployment -n kube-system aws-load-balancer-controller &>/dev/null; then
    echo "Warning: AWS Load Balancer Controller not found."
    echo "Install it with:"
    echo "  helm install aws-load-balancer-controller eks/aws-load-balancer-controller \\"
    echo "    -n kube-system --set clusterName=${CLUSTER_NAME}"
    echo ""
    read -p "Continue anyway? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

# Create namespace
echo "[1/7] Creating namespace..."
kubectl create namespace ${NAMESPACE} --dry-run=client -o yaml | kubectl apply -f -

# Apply ConfigMap
echo "[2/7] Applying ConfigMap..."
kubectl apply -f configmap.yaml -n ${NAMESPACE}

# Apply StatefulSet
echo "[3/7] Deploying StatefulSet (${REPLICAS} replicas)..."
kubectl apply -f statefulset.yaml -n ${NAMESPACE}
kubectl scale statefulset koorde-node --replicas=${REPLICAS} -n ${NAMESPACE}

# Apply Services
echo "[4/7] Creating Services..."
kubectl apply -f service-headless.yaml -n ${NAMESPACE}
kubectl apply -f service-cache.yaml -n ${NAMESPACE}
kubectl apply -f service-grpc.yaml -n ${NAMESPACE}

# Optional: Apply HPA
if [[ -f hpa.yaml ]]; then
    echo "[5/7] Applying HorizontalPodAutoscaler..."
    kubectl apply -f hpa.yaml -n ${NAMESPACE}
else
    echo "[5/7] Skipping HPA (file not found)"
fi

# Optional: Apply PDB
if [[ -f pdb.yaml ]]; then
    echo "[6/7] Applying PodDisruptionBudget..."
    kubectl apply -f pdb.yaml -n ${NAMESPACE}
else
    echo "[6/7] Skipping PDB (file not found)"
fi

# Wait for rollout
echo "[7/7] Waiting for pods to be ready..."
kubectl rollout status statefulset/koorde-node -n ${NAMESPACE} --timeout=10m

# Display status
echo ""
echo "============================================"
echo "  Deployment Status"
echo "============================================"
kubectl get pods -l app=koorde-node -n ${NAMESPACE}
echo ""

# Wait for Load Balancer
echo "Waiting for Load Balancer to be ready..."
sleep 10

HTTP_LB=$(kubectl get svc koorde-cache-http -n ${NAMESPACE} \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "pending")

GRPC_LB=$(kubectl get svc koorde-grpc -n ${NAMESPACE} \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "pending")

echo ""
echo "============================================"
echo "  Access Information"
echo "============================================"
echo "HTTP Cache Load Balancer: http://${HTTP_LB}"
echo "gRPC DHT Load Balancer: ${GRPC_LB}:4000"
echo ""
echo "Test commands:"
echo "  curl \"http://${HTTP_LB}/health\""
echo "  curl \"http://${HTTP_LB}/cache?url=https://httpbin.org/json\""
echo "  curl \"http://${HTTP_LB}/metrics\" | jq"
echo ""
echo "============================================"
echo "  Deployment Complete!"
echo "============================================"

