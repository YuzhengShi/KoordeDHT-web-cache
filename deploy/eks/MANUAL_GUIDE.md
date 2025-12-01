# Manual Operations Guide

This guide explains how to manually interact with the Chord/Koorde cluster on EKS, including scaling, changing configuration, and running custom benchmarks.

## 1. Scaling the Cluster (Add/Delete Nodes)

You can dynamically add or remove nodes using `kubectl scale`.

### Scale Up
To add nodes (e.g., scale to 50 nodes):

```bash
# For Chord
kubectl scale statefulset dht-node -n chord-dht --replicas=50

# For Koorde
kubectl scale statefulset dht-node -n koorde-dht --replicas=50
```

### Scale Down
To remove nodes (e.g., scale down to 5 nodes):

```bash
# For Chord
kubectl scale statefulset dht-node -n chord-dht --replicas=5
```

> **Note:** Scaling down gracefully handles node departure if the implementation supports `SIGTERM` handling (which it does). However, rapid scale-down of many nodes might cause temporary data unavailability until the ring stabilizes.

## 2. Changing Configuration (e.g., Degree)

The **Degree** (`k`) in Koorde determines the routing table size and hop count (log_k N).

> **IMPORTANT:** Changing the degree requires a **full cluster restart**. All nodes in the ring must agree on the degree for routing to work correctly.

### Step 1: Modify ConfigMap
Edit the `configmap-koorde.yaml` file:

```yaml
# deploy/eks/configmap-koorde.yaml
data:
  # ...
  DEBRUIJN_DEGREE: "4"  # Change from 8 to 4 (must be power of 2)
```

### Step 2: Apply Changes
Apply the new configuration to the cluster:

```bash
kubectl apply -f configmap-koorde.yaml -n koorde-dht
```

### Step 3: Restart Cluster
Since the degree is loaded at startup, you must restart the pods.

**Option A: Rolling Restart (Risky for Degree)**
*Not recommended for Degree changes as it creates a mixed-protocol state.*

**Option B: Full Redeploy (Recommended)**
Delete the StatefulSet (keeping the service/LB alive) and recreate it.

```bash
# Delete pods
kubectl delete statefulset dht-node -n koorde-dht

# Re-apply (this recreates the StatefulSet with new config)
# Note: You need to use the sed command to inject the namespace again
sed "s/NAMESPACE_PLACEHOLDER/koorde-dht/g" statefulset.yaml | kubectl apply -n koorde-dht -f -
```

## 3. Running Benchmarks Manually

You can run the `cache-workload` generator as a Kubernetes Job to test specific scenarios.

### Step 1: Get Load Balancer URL

```bash
LB_URL=$(kubectl get svc dht-cache-http -n koorde-dht -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo $LB_URL
```

### Step 2: Create Job Manifest
Create a file named `manual-benchmark.yaml`:

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: manual-benchmark
  namespace: koorde-dht
spec:
  template:
    spec:
      containers:
      - name: workload
        image: flaviosimonelli/cache-workload:latest
        args:
        - "--target"
        - "http://REPLACE_WITH_LB_URL"  # <--- Paste your LB URL here
        - "--requests"
        - "50000"       # Total requests
        - "--rate"
        - "200"         # Requests per second
        - "--urls"
        - "5000"        # Number of unique keys (Zipf distribution)
        - "--zipf"
        - "1.2"         # Zipf parameter (skew)
      restartPolicy: Never
  backoffLimit: 0
```

### Step 3: Run Job

```bash
# Replace URL in file (or edit manually)
sed -i "s/REPLACE_WITH_LB_URL/${LB_URL}/g" manual-benchmark.yaml

# Submit Job
kubectl apply -f manual-benchmark.yaml
```

### Step 4: Monitor and Get Results

```bash
# Watch status
kubectl get jobs -n koorde-dht -w

# Get logs (results)
kubectl logs job/manual-benchmark -n koorde-dht
```

### Step 5: Cleanup
Delete the job before running another one:

```bash
kubectl delete job manual-benchmark -n koorde-dht
```
