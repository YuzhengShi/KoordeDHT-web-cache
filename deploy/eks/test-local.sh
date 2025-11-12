#!/bin/bash
set -euo pipefail

echo "============================================"
echo "  Local Kubernetes Testing"
echo "============================================"
echo ""

# Check if kind is installed
if ! command -v kind &> /dev/null; then
    echo "Error: kind not installed. Install with:"
    echo "  brew install kind  # macOS"
    echo "  choco install kind # Windows"
    echo "  Or: go install sigs.k8s.io/kind@latest"
    exit 1
fi

# Check if kubectl is installed
if ! command -v kubectl &> /dev/null; then
    echo "Error: kubectl not installed."
    exit 1
fi

# Create cluster
echo "[1/6] Creating Kind cluster..."
if kind get clusters | grep -q koorde-local; then
    echo "Cluster 'koorde-local' already exists. Deleting..."
    kind delete cluster --name koorde-local
fi

kind create cluster --name koorde-local --config kind-config.yaml

# Deploy
echo "[2/6] Deploying Koorde..."
kubectl create namespace koorde-cache

kubectl apply -f configmap-local.yaml
kubectl apply -f statefulset-local.yaml
kubectl apply -f service-headless.yaml
kubectl apply -f service-cache-local.yaml

# Wait
echo "[3/6] Waiting for pods to be ready (this may take 2-3 minutes)..."
kubectl wait --for=condition=ready pod -l app=koorde-node -n koorde-cache --timeout=5m || {
    echo "Warning: Some pods not ready. Checking status..."
    kubectl get pods -n koorde-cache
}

# Check status
echo ""
echo "[4/6] Deployment status:"
kubectl get pods -n koorde-cache
echo ""
kubectl get svc -n koorde-cache

# Port forward
echo ""
echo "[5/6] Setting up port-forward on localhost:8080..."
kubectl port-forward -n koorde-cache svc/koorde-cache-http 8080:80 > /dev/null 2>&1 &
PF_PID=$!
sleep 3

# Test
echo ""
echo "[6/6] Running tests..."
echo "=========================================="
echo ""

echo "Test 1: Health check"
if curl -s -f "http://localhost:8080/health" > /dev/null 2>&1; then
    echo "✓ Health check passed"
    curl -s "http://localhost:8080/health" | jq 2>/dev/null || cat
else
    echo "✗ Health check failed"
fi

echo ""
echo "Test 2: Cache MISS (first request)"
echo -n "Fetching https://httpbin.org/json... "
START=$(date +%s%N)
RESPONSE=$(curl -s "http://localhost:8080/cache?url=https://httpbin.org/json" 2>/dev/null)
END=$(date +%s%N)
LATENCY=$(( (END - START) / 1000000 ))
if [ -n "$RESPONSE" ]; then
    CACHE_STATUS=$(curl -s -I "http://localhost:8080/cache?url=https://httpbin.org/json" 2>/dev/null | grep -i "X-Cache:" | cut -d' ' -f2 || echo "unknown")
    echo "✓ Success (${LATENCY}ms, X-Cache: ${CACHE_STATUS})"
else
    echo "✗ Failed"
fi

echo ""
echo "Test 3: Cache HIT (second request)"
echo -n "Fetching https://httpbin.org/json... "
START=$(date +%s%N)
RESPONSE=$(curl -s "http://localhost:8080/cache?url=https://httpbin.org/json" 2>/dev/null)
END=$(date +%s%N)
LATENCY=$(( (END - START) / 1000000 ))
if [ -n "$RESPONSE" ]; then
    CACHE_STATUS=$(curl -s -I "http://localhost:8080/cache?url=https://httpbin.org/json" 2>/dev/null | grep -i "X-Cache:" | cut -d' ' -f2 || echo "unknown")
    echo "✓ Success (${LATENCY}ms, X-Cache: ${CACHE_STATUS})"
else
    echo "✗ Failed"
fi

echo ""
echo "Test 4: Metrics"
if curl -s -f "http://localhost:8080/metrics" > /dev/null 2>&1; then
    echo "✓ Metrics available"
    echo ""
    curl -s "http://localhost:8080/metrics" | jq '{
      node: .node.id,
      cache_hit_rate: .cache.hit_rate,
      cache_hits: .cache.hits,
      cache_misses: .cache.misses,
      cache_entries: .cache.entry_count,
      hotspots: .hotspots.count,
      routing: .routing
    }' 2>/dev/null || echo "(jq not installed, showing raw)"
else
    echo "✗ Metrics failed"
fi

# Cleanup port-forward
kill $PF_PID 2>/dev/null || true

echo ""
echo "=========================================="
echo "  Testing Complete!"
echo "=========================================="
echo ""
echo "Cluster is still running at: koorde-local"
echo ""
echo "To access services:"
echo "  kubectl port-forward -n koorde-cache svc/koorde-cache-http 8080:80"
echo "  curl http://localhost:8080/cache?url=https://httpbin.org/json"
echo ""
echo "To view logs:"
echo "  kubectl logs -l app=koorde-node -n koorde-cache --tail=50"
echo ""
echo "To scale:"
echo "  kubectl scale statefulset koorde-node --replicas=10 -n koorde-cache"
echo ""
echo "To clean up:"
echo "  kind delete cluster --name koorde-local"
echo ""

