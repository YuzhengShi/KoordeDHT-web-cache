# AWS EKS Deployment with Load Balancer

Deploy KoordeDHT-Web-Cache to AWS Elastic Kubernetes Service (EKS) with Application Load Balancer for production workloads.

## Architecture

```
                  Internet
                     |
              [AWS ALB/NLB]
                     |
         ┌───────────┴───────────┐
         |                       |
    [Ingress/Service]      [Ingress/Service]
         |                       |
    HTTP Cache :8080        gRPC DHT :4000
         |                       |
    ┌────┴────────┬──────────────┴────┐
    |             |                    |
[Pod: node-0] [Pod: node-1]  ... [Pod: node-N]
    |             |                    |
StatefulSet with persistent identity
```

### Components

- **StatefulSet**: Koorde nodes with stable network identities
- **Headless Service**: Direct pod-to-pod DHT communication (gRPC)
- **LoadBalancer Service**: External access to HTTP cache API
- **ConfigMap**: Configuration for all nodes
- **ServiceAccount**: IAM roles for AWS integration
- **Ingress** (optional): TLS termination and path-based routing

---

## Prerequisites

### AWS Resources

1. **EKS Cluster**
   ```bash
   eksctl create cluster \
     --name koorde-cache \
     --region us-east-1 \
     --nodegroup-name standard-workers \
     --node-type t3.medium \
     --nodes 3 \
     --nodes-min 3 \
     --nodes-max 6 \
     --managed
   ```

2. **kubectl** configured
   ```bash
   aws eks update-kubeconfig --name koorde-cache --region us-east-1
   ```

3. **AWS Load Balancer Controller** installed
   ```bash
   # Install with Helm
   helm repo add eks https://aws.github.io/eks-charts
   helm repo update
   
   helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
     -n kube-system \
     --set clusterName=koorde-cache \
     --set serviceAccount.create=true \
     --set serviceAccount.name=aws-load-balancer-controller
   ```

4. **IAM OIDC Provider** (for service accounts)
   ```bash
   eksctl utils associate-iam-oidc-provider \
     --cluster koorde-cache \
     --approve
   ```

---

## Quick Start

### 1. Create Namespace

```bash
kubectl create namespace koorde-cache
kubectl config set-context --current --namespace=koorde-cache
```

### 2. Apply Configurations

```bash
# Apply all manifests
kubectl apply -f configmap.yaml
kubectl apply -f statefulset.yaml
kubectl apply -f service-headless.yaml
kubectl apply -f service-cache.yaml
kubectl apply -f service-grpc.yaml
```

### 3. Wait for Pods

```bash
# Watch pod startup
kubectl get pods -w

# Wait for all pods to be ready
kubectl wait --for=condition=ready pod -l app=koorde-node --timeout=300s
```

### 4. Get Load Balancer URL

```bash
# HTTP Cache Load Balancer
kubectl get svc koorde-cache-http -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'

# Example output: a1b2c3d4...us-east-1.elb.amazonaws.com
```

### 5. Test Cache

```bash
LB_URL=$(kubectl get svc koorde-cache-http -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

# Test cache request
curl "http://${LB_URL}/cache?url=https://httpbin.org/json"

# Check metrics
curl "http://${LB_URL}/metrics" | jq
```

---

## Configuration

### ConfigMap (configmap.yaml)

Shared configuration for all Koorde nodes:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: koorde-config
  namespace: koorde-cache
data:
  # DHT Configuration
  DHT_MODE: "private"
  DHT_ID_BITS: "66"
  DEBRUIJN_DEGREE: "8"
  SUCCESSOR_LIST_SIZE: "8"
  STABILIZATION_INTERVAL: "2s"
  FAILURE_TIMEOUT: "1s"
  DEBRUIJN_FIX_INTERVAL: "5s"
  STORAGE_FIX_INTERVAL: "20s"
  
  # Bootstrap Configuration
  BOOTSTRAP_MODE: "static"
  # Will be dynamically set to list of pod DNS names
  
  # Cache Configuration
  CACHE_ENABLED: "true"
  CACHE_HTTP_PORT: "8080"
  CACHE_CAPACITY_MB: "2048"
  CACHE_DEFAULT_TTL: "3600"
  CACHE_HOTSPOT_THRESHOLD: "1000.0"
  CACHE_HOTSPOT_DECAY: "0.65"
  
  # Logging
  LOGGER_ENABLED: "true"
  LOGGER_LEVEL: "info"
  LOGGER_ENCODING: "json"
  LOGGER_MODE: "stdout"
  
  # Tracing (optional - enable if using Jaeger)
  TRACING_ENABLED: "false"
```

### StatefulSet (statefulset.yaml)

Ensures stable pod identities and ordered deployment:

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: koorde-node
  namespace: koorde-cache
spec:
  serviceName: koorde-headless
  replicas: 10
  selector:
    matchLabels:
      app: koorde-node
  podManagementPolicy: Parallel
  template:
    metadata:
      labels:
        app: koorde-node
    spec:
      containers:
      - name: koorde
        image: flaviosimonelli/koorde-node:latest
        imagePullPolicy: Always
        ports:
        - containerPort: 4000
          name: grpc
          protocol: TCP
        - containerPort: 8080
          name: http
          protocol: TCP
        env:
        - name: NODE_BIND
          value: "0.0.0.0"
        - name: NODE_PORT
          value: "4000"
        - name: NODE_HOST
          valueFrom:
            fieldRef:
              fieldPath: status.podIP
        # Bootstrap peers: first 3 pods
        - name: BOOTSTRAP_PEERS
          value: "koorde-node-0.koorde-headless.koorde-cache.svc.cluster.local:4000,koorde-node-1.koorde-headless.koorde-cache.svc.cluster.local:4000,koorde-node-2.koorde-headless.koorde-cache.svc.cluster.local:4000"
        envFrom:
        - configMapRef:
            name: koorde-config
        resources:
          requests:
            memory: "512Mi"
            cpu: "250m"
          limits:
            memory: "2Gi"
            cpu: "1000m"
        livenessProbe:
          httpGet:
            path: /health
            port: 8080
          initialDelaySeconds: 30
          periodSeconds: 10
          timeoutSeconds: 5
          failureThreshold: 3
        readinessProbe:
          httpGet:
            path: /health
            port: 8080
          initialDelaySeconds: 15
          periodSeconds: 5
          timeoutSeconds: 3
          failureThreshold: 2
```

### Headless Service (service-headless.yaml)

For stable DNS names and direct pod-to-pod communication:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: koorde-headless
  namespace: koorde-cache
spec:
  clusterIP: None  # Headless service
  selector:
    app: koorde-node
  ports:
  - name: grpc
    port: 4000
    targetPort: 4000
    protocol: TCP
```

**Pod DNS names**:
- `koorde-node-0.koorde-headless.koorde-cache.svc.cluster.local`
- `koorde-node-1.koorde-headless.koorde-cache.svc.cluster.local`
- etc.

### HTTP Cache Load Balancer (service-cache.yaml)

External access to web cache API:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: koorde-cache-http
  namespace: koorde-cache
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-type: "nlb"  # Network Load Balancer
    service.beta.kubernetes.io/aws-load-balancer-cross-zone-load-balancing-enabled: "true"
    service.beta.kubernetes.io/aws-load-balancer-backend-protocol: "http"
spec:
  type: LoadBalancer
  selector:
    app: koorde-node
  ports:
  - name: http
    port: 80
    targetPort: 8080
    protocol: TCP
  sessionAffinity: None  # Round-robin load balancing
```

**For Application Load Balancer (ALB)**:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: koorde-cache-http
  namespace: koorde-cache
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-type: "external"
    service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: "ip"
    service.beta.kubernetes.io/aws-load-balancer-scheme: "internet-facing"
spec:
  type: LoadBalancer
  selector:
    app: koorde-node
  ports:
  - port: 80
    targetPort: 8080
    protocol: TCP
```

### gRPC Service (service-grpc.yaml)

Optional: External gRPC access for clients:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: koorde-grpc
  namespace: koorde-cache
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-type: "nlb"
spec:
  type: LoadBalancer
  selector:
    app: koorde-node
  ports:
  - name: grpc
    port: 4000
    targetPort: 4000
    protocol: TCP
```

---

## Deployment Script

Create `deploy-eks.sh`:

```bash
#!/bin/bash
set -euo pipefail

NAMESPACE="koorde-cache"
REPLICAS="${REPLICAS:-10}"

echo "Deploying KoordeDHT-Web-Cache to EKS..."

# Create namespace
kubectl create namespace ${NAMESPACE} --dry-run=client -o yaml | kubectl apply -f -

# Apply configurations
kubectl apply -f configmap.yaml -n ${NAMESPACE}

# Update replicas in statefulset
kubectl apply -f statefulset.yaml -n ${NAMESPACE}
kubectl scale statefulset koorde-node --replicas=${REPLICAS} -n ${NAMESPACE}

# Apply services
kubectl apply -f service-headless.yaml -n ${NAMESPACE}
kubectl apply -f service-cache.yaml -n ${NAMESPACE}
kubectl apply -f service-grpc.yaml -n ${NAMESPACE}

# Wait for rollout
echo "Waiting for pods to be ready..."
kubectl rollout status statefulset/koorde-node -n ${NAMESPACE} --timeout=5m

# Wait for load balancer
echo "Waiting for load balancer..."
kubectl wait --for=condition=ready \
  service/koorde-cache-http \
  -n ${NAMESPACE} \
  --timeout=5m

# Get load balancer URL
LB_URL=$(kubectl get svc koorde-cache-http -n ${NAMESPACE} \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

echo ""
echo "Deployment complete!"
echo "HTTP Cache URL: http://${LB_URL}"
echo ""
echo "Test with:"
echo "  curl \"http://${LB_URL}/cache?url=https://httpbin.org/json\""
echo "  curl \"http://${LB_URL}/metrics\" | jq"
```

Make it executable:
```bash
chmod +x deploy-eks.sh
```

---

## Scaling

### Horizontal Scaling

```bash
# Scale up to 20 nodes
kubectl scale statefulset koorde-node --replicas=20

# Scale down to 5 nodes
kubectl scale statefulset koorde-node --replicas=5
```

### Autoscaling (HPA)

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: koorde-node-hpa
  namespace: koorde-cache
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: StatefulSet
    name: koorde-node
  minReplicas: 5
  maxReplicas: 50
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 70
  - type: Resource
    resource:
      name: memory
      target:
        type: Utilization
        averageUtilization: 80
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 60
      policies:
      - type: Percent
        value: 50
        periodSeconds: 60
    scaleDown:
      stabilizationWindowSeconds: 300
      policies:
      - type: Pods
        value: 2
        periodSeconds: 120
```

Apply:
```bash
kubectl apply -f hpa.yaml
```

---

## Load Balancer Configuration

### Option 1: Network Load Balancer (NLB) - Recommended

**Best for**: High throughput, low latency, TCP/HTTP traffic

```yaml
# service-cache-nlb.yaml
apiVersion: v1
kind: Service
metadata:
  name: koorde-cache-http
  namespace: koorde-cache
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-type: "external"
    service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: "ip"
    service.beta.kubernetes.io/aws-load-balancer-scheme: "internet-facing"
    service.beta.kubernetes.io/aws-load-balancer-cross-zone-load-balancing-enabled: "true"
    service.beta.kubernetes.io/aws-load-balancer-healthcheck-protocol: "http"
    service.beta.kubernetes.io/aws-load-balancer-healthcheck-path: "/health"
    service.beta.kubernetes.io/aws-load-balancer-healthcheck-interval: "10"
    service.beta.kubernetes.io/aws-load-balancer-healthcheck-timeout: "5"
    service.beta.kubernetes.io/aws-load-balancer-healthy-threshold: "2"
    service.beta.kubernetes.io/aws-load-balancer-unhealthy-threshold: "2"
spec:
  type: LoadBalancer
  selector:
    app: koorde-node
  ports:
  - name: http
    port: 80
    targetPort: 8080
    protocol: TCP
```

### Option 2: Application Load Balancer (ALB) with Ingress

**Best for**: HTTP/HTTPS, path-based routing, TLS termination

```yaml
# ingress-alb.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: koorde-cache-ingress
  namespace: koorde-cache
  annotations:
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTP": 80}, {"HTTPS": 443}]'
    alb.ingress.kubernetes.io/ssl-redirect: '443'
    alb.ingress.kubernetes.io/certificate-arn: arn:aws:acm:us-east-1:123456789012:certificate/abc123
    alb.ingress.kubernetes.io/healthcheck-path: /health
    alb.ingress.kubernetes.io/healthcheck-interval-seconds: '15'
    alb.ingress.kubernetes.io/healthcheck-timeout-seconds: '5'
    alb.ingress.kubernetes.io/healthy-threshold-count: '2'
    alb.ingress.kubernetes.io/unhealthy-threshold-count: '2'
spec:
  ingressClassName: alb
  rules:
  - host: cache.example.com
    http:
      paths:
      - path: /cache
        pathType: Prefix
        backend:
          service:
            name: koorde-cache-http-internal
            port:
              number: 8080
      - path: /metrics
        pathType: Exact
        backend:
          service:
            name: koorde-cache-http-internal
            port:
              number: 8080
      - path: /health
        pathType: Exact
        backend:
          service:
            name: koorde-cache-http-internal
            port:
              number: 8080
```

**Internal Service for ALB**:

```yaml
# service-cache-internal.yaml
apiVersion: v1
kind: Service
metadata:
  name: koorde-cache-http-internal
  namespace: koorde-cache
spec:
  type: ClusterIP
  selector:
    app: koorde-node
  ports:
  - name: http
    port: 8080
    targetPort: 8080
    protocol: TCP
```

---

## Monitoring

### Prometheus Integration

```yaml
# servicemonitor.yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: koorde-cache-metrics
  namespace: koorde-cache
spec:
  selector:
    matchLabels:
      app: koorde-node
  endpoints:
  - port: http
    path: /metrics
    interval: 30s
```

### CloudWatch Container Insights

```bash
# Install CloudWatch agent
kubectl apply -f https://raw.githubusercontent.com/aws-samples/amazon-cloudwatch-container-insights/latest/k8s-deployment-manifest-templates/deployment-mode/daemonset/container-insights-monitoring/cloudwatch-namespace.yaml

kubectl apply -f https://raw.githubusercontent.com/aws-samples/amazon-cloudwatch-container-insights/latest/k8s-deployment-manifest-templates/deployment-mode/daemonset/container-insights-monitoring/cwagent/cwagent-serviceaccount.yaml
```

---

## Advanced Features

### 1. TLS Termination

```yaml
# Update ingress for HTTPS
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: koorde-cache-ingress
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
spec:
  tls:
  - hosts:
    - cache.example.com
    secretName: koorde-cache-tls
  rules:
  - host: cache.example.com
    # ... paths
```

### 2. Pod Disruption Budget

Ensure availability during updates:

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: koorde-node-pdb
  namespace: koorde-cache
spec:
  minAvailable: 3
  selector:
    matchLabels:
      app: koorde-node
```

### 3. Resource Quotas

```yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: koorde-cache-quota
  namespace: koorde-cache
spec:
  hard:
    requests.cpu: "20"
    requests.memory: "40Gi"
    limits.cpu: "40"
    limits.memory: "80Gi"
    persistentvolumeclaims: "10"
```

### 4. Network Policies

Restrict traffic between pods:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: koorde-node-netpol
  namespace: koorde-cache
spec:
  podSelector:
    matchLabels:
      app: koorde-node
  policyTypes:
  - Ingress
  - Egress
  ingress:
  - from:
    - podSelector:
        matchLabels:
          app: koorde-node
    ports:
    - protocol: TCP
      port: 4000  # gRPC
  - from: []  # Allow all for HTTP cache
    ports:
    - protocol: TCP
      port: 8080
  egress:
  - to:
    - podSelector:
        matchLabels:
          app: koorde-node
    ports:
    - protocol: TCP
      port: 4000
  - to: []  # Allow all for fetching from origin
    ports:
    - protocol: TCP
      port: 80
    - protocol: TCP
      port: 443
```

---

## Testing

### Access from Outside Cluster

```bash
LB_URL=$(kubectl get svc koorde-cache-http -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

# Cache test
curl "http://${LB_URL}/cache?url=https://httpbin.org/json"

# Metrics
curl "http://${LB_URL}/metrics" | jq '.cache'

# Health check
curl "http://${LB_URL}/health"
```

### Access from Inside Cluster

```bash
# Port-forward to specific pod
kubectl port-forward koorde-node-0 8080:8080 4000:4000

# Test locally
curl "http://localhost:8080/cache?url=https://httpbin.org/json"
```

### Interactive Client

```bash
# Run client pod
kubectl run -it --rm koorde-client \
  --image=flaviosimonelli/koorde-client:latest \
  --restart=Never \
  -- --addr koorde-node-0.koorde-headless.koorde-cache.svc.cluster.local:4000
```

---

## Load Testing

### Using cache-workload

```bash
# Build workload generator
docker build -t cache-workload:latest -f docker/workload.Dockerfile .

# Run as Kubernetes Job
kubectl create job cache-workload \
  --image=cache-workload:latest \
  -- --target http://koorde-cache-http.koorde-cache.svc.cluster.local \
     --urls 1000 \
     --requests 10000 \
     --rate 100 \
     --zipf 0.9
```

### Using kubectl run

```bash
LB_URL=$(kubectl get svc koorde-cache-http -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

kubectl run -it --rm load-test \
  --image=curlimages/curl:latest \
  --restart=Never \
  -- sh -c "
  for i in {1..100}; do
    curl -s 'http://${LB_URL}/cache?url=https://httpbin.org/json' > /dev/null &
  done
  wait
  "
```

---

## Observability

### View Logs

```bash
# All pods
kubectl logs -l app=koorde-node --tail=100 -f

# Specific pod
kubectl logs koorde-node-0 -f

# Previous instance (after restart)
kubectl logs koorde-node-0 --previous
```

### Exec into Pod

```bash
kubectl exec -it koorde-node-0 -- sh

# Check routing table via gRPC (if client installed)
kubectl exec -it koorde-node-0 -- \
  /usr/local/bin/koorde-client --addr localhost:4000 getrt
```

### Metrics

```bash
# Per-pod metrics
kubectl top pods -l app=koorde-node

# Node metrics
kubectl top nodes
```

---

## Updates & Rollouts

### Rolling Update

```bash
# Update image
kubectl set image statefulset/koorde-node \
  koorde=flaviosimonelli/koorde-node:v2.0.0

# Monitor rollout
kubectl rollout status statefulset/koorde-node

# Rollback if needed
kubectl rollout undo statefulset/koorde-node
```

### Blue-Green Deployment

```yaml
# Deploy new version alongside old
kubectl apply -f statefulset-v2.yaml

# Switch traffic to new version
kubectl patch service koorde-cache-http -p '{"spec":{"selector":{"version":"v2"}}}'

# Delete old version
kubectl delete statefulset koorde-node-v1
```

---

## Backup & Disaster Recovery

### Export DHT State

```bash
# For each pod, export storage
for i in {0..9}; do
  kubectl exec koorde-node-$i -- \
    /usr/local/bin/koorde-client --addr localhost:4000 getstore > backup-node-$i.json
done
```

### Restore

```bash
# Restore data to new cluster
for i in {0..9}; do
  cat backup-node-$i.json | \
  kubectl exec -i koorde-node-$i -- \
    /usr/local/bin/koorde-client --addr localhost:4000 put <key> <value>
done
```

---

## Cost Optimization

### Use Spot Instances

```bash
eksctl create nodegroup \
  --cluster koorde-cache \
  --name spot-nodes \
  --node-type t3.medium \
  --nodes 3 \
  --nodes-min 3 \
  --nodes-max 10 \
  --spot
```

### Cluster Autoscaler

```bash
# Install cluster autoscaler
kubectl apply -f https://raw.githubusercontent.com/kubernetes/autoscaler/master/cluster-autoscaler/cloudprovider/aws/examples/cluster-autoscaler-autodiscover.yaml

kubectl annotate serviceaccount cluster-autoscaler \
  -n kube-system \
  eks.amazonaws.com/role-arn=arn:aws:iam::123456789012:role/ClusterAutoscalerRole
```

### Reserved Capacity

For production:
```bash
eksctl create nodegroup \
  --cluster koorde-cache \
  --name reserved-nodes \
  --node-type t3.medium \
  --nodes 5 \
  --capacity-type ON_DEMAND
```

---

## Security

### IAM Roles for Service Accounts (IRSA)

```bash
# Create IAM policy for Route53 access
aws iam create-policy \
  --policy-name KoordeCacheRoute53Policy \
  --policy-document file://route53-policy.json

# Create service account
eksctl create iamserviceaccount \
  --cluster koorde-cache \
  --namespace koorde-cache \
  --name koorde-node-sa \
  --attach-policy-arn arn:aws:iam::123456789012:policy/KoordeCacheRoute53Policy \
  --approve
```

### Secrets Management

```bash
# Create secret for sensitive configs
kubectl create secret generic koorde-secrets \
  --from-literal=aws-access-key-id=$AWS_ACCESS_KEY_ID \
  --from-literal=aws-secret-access-key=$AWS_SECRET_ACCESS_KEY \
  -n koorde-cache
```

---

## Troubleshooting

### Pods Not Starting

```bash
# Describe pod
kubectl describe pod koorde-node-0

# Check events
kubectl get events --sort-by='.lastTimestamp' -n koorde-cache

# Check logs
kubectl logs koorde-node-0
```

### DHT Not Stabilizing

```bash
# Check bootstrap pods are running
kubectl get pods -l app=koorde-node | head -n 4

# Verify DNS resolution
kubectl exec koorde-node-5 -- \
  nslookup koorde-node-0.koorde-headless.koorde-cache.svc.cluster.local

# Check connectivity
kubectl exec koorde-node-5 -- \
  nc -zv koorde-node-0.koorde-headless.koorde-cache.svc.cluster.local 4000
```

### Load Balancer Not Ready

```bash
# Check service
kubectl describe svc koorde-cache-http

# Verify AWS Load Balancer Controller is running
kubectl get deployment -n kube-system aws-load-balancer-controller

# Check target groups in AWS Console
aws elbv2 describe-target-groups
```

### High Latency

```bash
# Check pod resources
kubectl top pods -l app=koorde-node

# Check if pods are being throttled
kubectl describe pod koorde-node-0 | grep -i throttl

# Increase resources
kubectl patch statefulset koorde-node -p '{"spec":{"template":{"spec":{"containers":[{"name":"koorde","resources":{"limits":{"cpu":"2000m","memory":"4Gi"}}}]}}}}'
```

---

## Production Checklist

- [ ] Enable autoscaling (HPA + Cluster Autoscaler)
- [ ] Configure pod disruption budgets
- [ ] Set up monitoring (Prometheus/CloudWatch)
- [ ] Configure alerting (AlertManager/SNS)
- [ ] Enable TLS for external traffic
- [ ] Implement network policies
- [ ] Use IRSA for AWS permissions
- [ ] Configure log aggregation (EFK/CloudWatch Logs)
- [ ] Set resource quotas per namespace
- [ ] Enable backup/restore procedures
- [ ] Document runbooks for incidents
- [ ] Load test with expected traffic

---

## Cost Estimation

For production deployment:

| Resource | Configuration | Monthly Cost (approx) |
|----------|--------------|----------------------|
| EKS Control Plane | 1 cluster | $73 |
| EC2 Nodes | 3 × t3.medium | $100 |
| Load Balancer | 1 NLB | $20 |
| Data Transfer | 100 GB | $9 |
| **Total** | | **~$200/month** |

For development:
- Use t3.small nodes: ~$50/month
- Single node cluster: ~$90/month
- Stop cluster when not in use

---

## Next Steps

1. Review and customize manifests for your use case
2. Deploy to development EKS cluster
3. Run load tests and tune performance
4. Set up monitoring and alerting
5. Document operational procedures
6. Deploy to production

---

## References

- [EKS Best Practices](https://aws.github.io/aws-eks-best-practices/)
- [AWS Load Balancer Controller](https://kubernetes-sigs.github.io/aws-load-balancer-controller/)
- [StatefulSet Documentation](https://kubernetes.io/docs/concepts/workloads/controllers/statefulset/)
- [Horizontal Pod Autoscaling](https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale/)

