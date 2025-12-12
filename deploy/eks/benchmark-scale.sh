#!/bin/bash
set -euo pipefail

# Configuration
REPLICAS=1000
WAIT_TIME=600 # 10 minutes for stabilization
RESULTS_DIR="benchmark_results_$(date +%Y%m%d_%H%M%S)"
mkdir -p "${RESULTS_DIR}"

run_benchmark() {
    local PROTOCOL=$1
    local NAMESPACE="${PROTOCOL}-dht"
    
    echo "=================================================="
    echo "Starting Benchmark for ${PROTOCOL} (Target: ${REPLICAS} nodes)"
    echo "=================================================="
    
    # 1. Deploy (using high density config)
    echo "[1/6] Deploying initial cluster..."
    kubectl create namespace ${NAMESPACE} --dry-run=client -o yaml | kubectl apply -f -
    kubectl apply -f configmap-${PROTOCOL}.yaml -n ${NAMESPACE}
    
    # Use high-density statefulset
    sed "s/NAMESPACE_PLACEHOLDER/${NAMESPACE}/g" statefulset-high-density.yaml | kubectl apply -n ${NAMESPACE} -f -
    
    kubectl apply -f service-headless.yaml -n ${NAMESPACE}
    kubectl apply -f service-cache.yaml -n ${NAMESPACE}
    kubectl apply -f service-grpc.yaml -n ${NAMESPACE}
    
    # 2. Scale Up
    echo "[2/6] Scaling to ${REPLICAS} replicas..."
    kubectl scale statefulset dht-node --replicas=${REPLICAS} -n ${NAMESPACE}
    
    echo "Waiting for rollout (this may take a while)..."
    # Wait in chunks to avoid timeout
    kubectl rollout status statefulset/dht-node -n ${NAMESPACE} --timeout=20m
    
    # 3. Stabilization
    echo "[3/6] Waiting ${WAIT_TIME}s for DHT stabilization..."
    sleep ${WAIT_TIME}
    
    # 4. Run Workload
    echo "[4/6] Running workload generator..."
    
    # Get Load Balancer URL
    LB_URL=$(kubectl get svc dht-cache-http -n ${NAMESPACE} -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
    echo "Load Balancer: ${LB_URL}"
    
    # Create Job for workload
    cat <<EOF | kubectl apply -n ${NAMESPACE} -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: benchmark-workload
spec:
  template:
    spec:
      containers:
      - name: workload
        image: flaviosimonelli/cache-workload:latest
        args:
        - "--target"
        - "http://${LB_URL}"
        - "--requests"
        - "100000"
        - "--rate"
        - "500"
        - "--urls"
        - "10000"
      restartPolicy: Never
  backoffLimit: 1
EOF
    
    echo "Waiting for workload to complete..."
    kubectl wait --for=condition=complete job/benchmark-workload -n ${NAMESPACE} --timeout=10m
    
    # 5. Collect Results
    echo "[5/6] Collecting results..."
    kubectl logs job/benchmark-workload -n ${NAMESPACE} > "${RESULTS_DIR}/${PROTOCOL}_results.txt"
    
    # 6. Cleanup
    echo "[6/6] Cleaning up..."
    kubectl delete namespace ${NAMESPACE}
    
    echo "Benchmark for ${PROTOCOL} complete."
    echo "Results saved to ${RESULTS_DIR}/${PROTOCOL}_results.txt"
    echo ""
}

# Run for both protocols
run_benchmark "chord"
run_benchmark "koorde"

echo "All benchmarks completed."
