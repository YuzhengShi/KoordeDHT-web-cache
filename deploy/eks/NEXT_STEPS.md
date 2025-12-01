# Next Steps & Experiments

Now that your Koorde deployment is working, here are suggested next steps:

## 🧪 Immediate Experiments (This Session)

### 1. Deploy Chord for Comparison
```bash
cd /mnt/d/CS6650/KoordeDHT-web-cache/deploy/eks
./deploy-eks.sh chord
```

**Wait ~2 minutes, then verify:**
```bash
kubectl get pods -n chord-dht
curl "http://$(kubectl get svc dht-cache-http -n chord-dht -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')/health"
```

### 2. Compare Routing Performance
```bash
# Get both LB URLs
KOORDE_LB=$(kubectl get svc dht-cache-http -n koorde-dht -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
CHORD_LB=$(kubectl get svc dht-cache-http -n chord-dht -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

# Test Koorde
time for i in {1..100}; do curl -s "http://${KOORDE_LB}/cache?url=https://httpbin.org/uuid" > /dev/null; done

# Test Chord
time for i in {1..100}; do curl -s "http://${CHORD_LB}/cache?url=https://httpbin.org/uuid" > /dev/null; done
```

### 3. Check Routing Statistics
```bash
# Koorde stats
curl "http://${KOORDE_LB}/metrics" | jq '.routing.stats'

# Chord stats
curl "http://${CHORD_LB}/metrics" | jq '.routing.stats'
```

---

## 📊 Advanced Experiments (Next Session)

### 1. Scale Testing
```bash
# Scale Koorde to 50 nodes
kubectl scale statefulset dht-node -n koorde-dht --replicas=50

# Monitor scaling
kubectl get pods -n koorde-dht -w

# Check how many de Bruijn fingers now (should be 2-3 for k=8, N=50)
curl "http://${KOORDE_LB}/metrics" | jq '.routing.debruijn_count'
```

### 2. Degree Comparison
Test different de Bruijn degrees to see impact on routing:

```bash
# Edit configmap-koorde.yaml
# Change: DEBRUIJN_DEGREE: "2"  # or "4", "16"

kubectl apply -f configmap-koorde.yaml -n koorde-dht
kubectl delete pods -l app=dht-node -n koorde-dht  # Force restart
```

**Expected behavior:**
- `k=2`: More fingers (log₂N), more routing hops, more connections
- `k=16`: Fewer fingers (log₁₆N), fewer hops, fewer connections

### 3. Load Testing with Workload Generator
```bash
# Build workload tool
cd /mnt/d/CS6650/KoordeDHT-web-cache
go build -o cache-workload ./cmd/cache-workload

# Run realistic workload
./cache-workload \
  --target "http://${KOORDE_LB}" \
  --requests 100000 \
  --urls 10000 \
  --rate 500 \
  --zipf 1.2 \
  --output koorde-results.csv

# Compare with Chord
./cache-workload \
  --target "http://${CHORD_LB}" \
  --requests 100000 \
  --urls 10000 \
  --rate 500 \
  --zipf 1.2 \
  --output chord-results.csv

# Analyze results
python3 analyze_results.py koorde-results.csv chord-results.csv
```

### 4. Fault Tolerance Testing
```bash
# Kill a random node
kubectl delete pod dht-node-5 -n koorde-dht

# Watch self-healing
kubectl get pods -n koorde-dht -w

# Verify cache still works
curl "http://${KOORDE_LB}/cache?url=https://httpbin.org/json"
```

---

## 🔬 Research Questions to Answer

### Performance Comparison
- **Latency**: Which protocol has lower average latency?
- **Throughput**: Requests/sec at saturation?
- **Scalability**: Performance degradation with N nodes?

### Routing Efficiency
- **Hop count**: Average hops to find a key (Koorde should be O(log N / log k))
- **Finger usage**: How often are de Bruijn shortcuts used vs successor fallback?
- **Load distribution**: Are keys evenly distributed across nodes?

### Degree Optimization
- **Sweet spot**: What degree (k) gives best performance for your workload?
- **Trade-off**: Routing hops vs connection overhead

---

## 📈 Metrics to Collect

### From `/metrics` endpoint:
```bash
# Cache metrics
- Hit rate
- Latency
- Size/utilization

# Routing metrics
- debruijn_success / debruijn_failures
- avg_de_bruijn_success_ms
- successor_fallbacks

# Node health
- successor_count
- debruijn_count
```

### From Kubernetes:
```bash
# Resource usage
kubectl top pods -n koorde-dht
kubectl top pods -n chord-dht

# Network traffic
kubectl describe svc dht-cache-http -n koorde-dht
```

---

## 🎯 Benchmark Script (Optional)

For automated comparison at scale:
```bash
cd deploy/eks
./benchmark-scale.sh  # Runs 1000-node test for both protocols
```

**⚠️ Warning:** This takes ~40 minutes and uses significant resources!

---

## 📝 Remember Before Session Ends

```bash
# Save results
cp *.csv ~/
kubectl get all -n koorde-dht -o yaml > ~/koorde-backup.yaml
kubectl get all -n chord-dht -o yaml > ~/chord-backup.yaml

# Cleanup
eksctl delete cluster --name koorde-cache --region us-west-2 --wait
```

Next session: Your Docker image is already in ECR, so you can skip the build step!
