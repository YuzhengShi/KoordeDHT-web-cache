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

### AWS Learner Lab Setup (us-west-2)

1. **Login to AWS Learner Lab**
   - Go to your learning platform and start the AWS Learner Lab.
   - Click **AWS Details** to see your credentials.
   - Click **Show** next to "AWS CLI".

   > **Tip:** For a clean setup, see our [Virtual Environment Setup Guide](SETUP_VENV.md) to install tools in an isolated environment.

2. **Configure AWS CLI**
   - Copy the text from the "AWS CLI" box.
   - Paste it into your `~/.aws/credentials` file (or run `aws configure`).
   - Ensure your region is set to `us-west-2`.

   ```bash
   aws configure set region us-west-2
   ```

3. **Create EKS Cluster**
   - Use `eksctl` to create the cluster. This will take ~15-20 minutes.
   
   ```bash
   eksctl create cluster -f deploy/eks/cluster-config.yaml
   
   ```

4. **Configure kubectl**
   - Once the cluster is ready, update your kubeconfig:
   
   ```bash
   aws eks update-kubeconfig --name koorde-cache --region us-west-2
   ```

5. **Install Load Balancer Controller (Required for External Access)**
   - **Note for Learner Lab:** You might need to use the existing `LabRole` if you lack permissions to create new IAM roles. However, standard installation often works if you have `AdministratorAccess` (which Learner Lab usually provides).

   ```bash
   # Add Helm repo
   helm repo add eks https://aws.github.io/eks-charts
   helm repo update
   
   # Install Controller
   helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
     -n kube-system \
     --set clusterName=koorde-cache \
     --set serviceAccount.create=false \
     --set serviceAccount.name=default
   ```
   *(Note: In a production environment, you would use IRSA (IAM Roles for Service Accounts), but for Learner Lab, using the default node role is often easier if IRSA setup is restricted.)*

---

## Build and Push Docker Image to ECR

Before deploying, you need to build the Docker image and push it to Amazon ECR:

```bash
# Navigate to deploy/eks directory
cd deploy/eks

# Run the build and push script
./build-and-push-ecr.sh
```

This script will:
1. Create an ECR repository (if it doesn't exist)
2. Authenticate Docker to ECR
3. Build the Docker image from `docker/node.Dockerfile`
4. Tag and push the image to ECR

The image URI will be: `<ACCOUNT_ID>.dkr.ecr.us-west-2.amazonaws.com/koorde-node:latest`

> **Note:** Make sure you have Docker running and AWS CLI configured before running this script.

---

## Quick Start

### 1. Deploy Chord or Koorde

```bash
# Deploy Chord
./deploy-eks.sh chord

# Deploy Koorde
./deploy-eks.sh koorde
```

### 2. Wait for Pods

```bash
# Watch pod startup (use namespace for the protocol you deployed)
kubectl get pods -n koorde-dht -w
# or for Chord:
kubectl get pods -n chord-dht -w

# Wait for all pods to be ready
kubectl wait --for=condition=ready pod -l app=dht-node -n koorde-dht --timeout=300s
# or for Chord:
kubectl wait --for=condition=ready pod -l app=dht-node -n chord-dht --timeout=300s
```

### 3. Get Load Balancer URL

```bash
# HTTP Cache Load Balancer (use the namespace for your protocol)

# For Koorde
kubectl get svc dht-cache-http -n koorde-dht -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'

# For Chord
kubectl get svc dht-cache-http -n chord-dht -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'

# Example output: k8s-koordedh-dhtcache-xxxxx.elb.us-west-2.amazonaws.com
```

### 4. Test Cache

```bash
# Set the Load Balancer URL (for Koorde)
LB_URL=$(kubectl get svc dht-cache-http -n koorde-dht -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

# Set the Load Balancer URL (for Chord)
LB_URL=$(kubectl get svc dht-cache-http -n chord-dht -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

# Test cache request
curl "http://${LB_URL}/cache?url=https://httpbin.org/json"

# Check metrics (includes DHT routing stats)
curl "http://${LB_URL}/metrics" | jq
```

### 5. Run Workload Generator

```bash
# Run workload to generate DHT traffic
./cache-workload --target http://${LB_URL} --urls 100 --requests 1000 --rate 100 --zipf 1.2

# Check metrics after workload to verify de Bruijn routing usage
curl "http://${LB_URL}/metrics" | jq '.routing'
```

Expected output shows de Bruijn routing activity:
```json
{
  "debruijn_count": 8,
  "has_predecessor": true,
  "stats": {
    "de_bruijn_success": 14782,
    "de_bruijn_failures": 0,
    "protocol": "koorde",
    "successor_fallbacks": 353
  }
}
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
# Scale up to 20 nodes (use correct namespace)
kubectl scale statefulset dht-node --replicas=20 -n koorde-dht
kubectl scale statefulset dht-node --replicas=20 -n chord-dht

# Scale down to 5 nodes
kubectl scale statefulset dht-node --replicas=5 -n koorde-dht
kubectl scale statefulset dht-node --replicas=5 -n chord-dht
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
    alb.ingress.kubernetes.io/certificate-arn: arn:aws:acm:us-west-2:123456789012:certificate/abc123
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
# Get the Load Balancer URL (use correct namespace)
LB_URL=$(kubectl get svc dht-cache-http -n koorde-dht -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

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
kubectl port-forward dht-node-0 8080:8080 4000:4000 -n koorde-dht

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

# Get the Load Balancer URL
LB_URL=$(kubectl get svc dht-cache-http -n koorde-dht -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

# Run workload from local machine
./cache-workload --target http://${LB_URL} --urls 1000 --requests 10000 --rate 100 --zipf 1.2
```

### Using kubectl run

```bash
LB_URL=$(kubectl get svc dht-cache-http -n koorde-dht -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

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
# All pods in namespace
kubectl logs -l app=dht-node -n koorde-dht --tail=100 -f

# Specific pod
kubectl logs dht-node-0 -n koorde-dht -f

# Previous instance (after restart)
kubectl logs dht-node-0 -n koorde-dht --previous
```

### Exec into Pod

```bash
kubectl exec -it dht-node-0 -n koorde-dht -- sh
```

### Metrics

```bash
# Per-pod metrics
kubectl top pods -l app=dht-node -n koorde-dht

# Node metrics
kubectl top nodes
```

---

## Updates & Rollouts

### Rolling Update

```bash
# Update image (use your ECR URI)
kubectl set image statefulset/dht-node \
  dht-node=<ACCOUNT_ID>.dkr.ecr.us-west-2.amazonaws.com/koorde-node:v2.0.0 \
  -n koorde-dht

# Monitor rollout
kubectl rollout status statefulset/dht-node -n koorde-dht

# Rollback if needed
kubectl rollout undo statefulset/dht-node -n koorde-dht
```

### Blue-Green Deployment

```yaml
# Deploy new version alongside old
kubectl apply -f statefulset-v2.yaml -n koorde-dht

# Switch traffic to new version
kubectl patch service dht-cache-http -n koorde-dht -p '{"spec":{"selector":{"version":"v2"}}}'

# Delete old version
kubectl delete statefulset dht-node-v1 -n koorde-dht
```

---

## Backup & Disaster Recovery

### Export DHT State

```bash
# For each pod, export storage
for i in {0..9}; do
  kubectl exec dht-node-$i -n koorde-dht -- \
    cat /tmp/dht-state.json > backup-node-$i.json 2>/dev/null || echo "No state for node $i"
done
```

### Restore

```bash
# Restore is application-specific
# DHT state is typically rebuilt automatically when nodes rejoin the ring
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
kubectl describe pod dht-node-0 -n koorde-dht

# Check events
kubectl get events --sort-by='.lastTimestamp' -n koorde-dht

# Check logs
kubectl logs dht-node-0 -n koorde-dht
```

### DHT Not Stabilizing

```bash
# Check bootstrap pods are running
kubectl get pods -l app=dht-node -n koorde-dht | head -n 4

# Verify DNS resolution
kubectl exec dht-node-5 -n koorde-dht -- \
  nslookup dht-node-0.dht-headless.koorde-dht.svc.cluster.local

# Check connectivity
kubectl exec dht-node-5 -n koorde-dht -- \
  nc -zv dht-node-0.dht-headless.koorde-dht.svc.cluster.local 4000
```

### Load Balancer Not Ready

```bash
# Check service
kubectl describe svc dht-cache-http -n koorde-dht

# Verify AWS Load Balancer Controller is running
kubectl get deployment -n kube-system aws-load-balancer-controller

# Check target groups in AWS Console
aws elbv2 describe-target-groups
```

### High Latency

```bash
# Check pod resources
kubectl top pods -l app=dht-node -n koorde-dht

# Check if pods are being throttled
kubectl describe pod dht-node-0 -n koorde-dht | grep -i throttl

# Increase resources
kubectl patch statefulset dht-node -n koorde-dht -p '{"spec":{"template":{"spec":{"containers":[{"name":"dht-node","resources":{"limits":{"cpu":"2000m","memory":"4Gi"}}}]}}}}'
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

## Benchmarking and Comparing KoordeDHT vs Chord

You can benchmark and compare KoordeDHT and Chord at various cluster sizes using the following steps:

### 1. Deploy Both Systems

- Deploy KoordeDHT:
  ```bash
  ./deploy-eks.sh koorde
  ```
- Deploy Chord:
  ```bash
  ./deploy-eks.sh chord
  ```

### 2. Scale the Number of Nodes

Adjust the number of nodes for each system as needed:
```bash
# For Koorde (namespace: koorde-dht)
kubectl scale statefulset dht-node --replicas=20 -n koorde-dht

# For Chord (namespace: chord-dht)
kubectl scale statefulset dht-node --replicas=20 -n chord-dht
```
Change `20` to your desired node count.

### 3. Wait for All Pods to Be Ready

Monitor pod status:
```bash
kubectl get pods -n koorde-dht -w
kubectl get pods -n chord-dht -w
```

### 4. Run Workload Generator

For each system, run the workload generator targeting the respective load balancer:
```bash
# For Koorde
LB_KOORDE=$(kubectl get svc dht-cache-http -n koorde-dht -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
./cache-workload --target http://${LB_KOORDE} --urls 1000 --requests 10000 --rate 100 --zipf 1.2

# For Chord
LB_CHORD=$(kubectl get svc dht-cache-http -n chord-dht -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
./cache-workload --target http://${LB_CHORD} --urls 1000 --requests 10000 --rate 100 --zipf 1.2
```

### 5. Collect and Save Results

- Save the results from each run (e.g., `results-koorde.csv`, `results-chord.csv`).
- Fetch `/metrics` from each system after the workload for detailed routing and cache stats:
  ```bash
  curl "http://${LB_KOORDE}/metrics" | jq > metrics-koorde.json
  curl "http://${LB_CHORD}/metrics" | jq > metrics-chord.json
  ```

### 6. Scale Up for Large Node Counts

- Increase the number of replicas as needed and repeat the tests.
- Monitor pod health and resource usage:
  ```bash
  kubectl top pods -n koorde-dht
  kubectl top pods -n chord-dht
  ```

### 7. Analyze and Compare

- Compare latency, throughput, cache hit/miss rates, and routing metrics between Koorde and Chord.
- Look for scalability trends as you increase the number of nodes.

### 8. Automate (Optional)

- Use or adapt the provided benchmark scripts (e.g., `benchmark-chord-vs-koorde.ps1`, `benchmark-koorde-only.ps1`) to automate multi-run comparisons.

---

## Cleanup and Shutdown

### Save Your Results Before Shutdown

```bash
# Export experiment data
kubectl get pods -n koorde-dht -o wide > pod-status.txt
kubectl top pods -n koorde-dht > resource-usage.txt 2>/dev/null || true

# Save metrics
LB_URL=$(kubectl get svc dht-cache-http -n koorde-dht -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
curl "http://${LB_URL}/metrics" | jq > final-metrics.json

# Copy any result CSVs
cp results*.csv ~/
```

### Delete Deployment (Keep Cluster)

To remove the DHT deployment but keep the EKS cluster running:

```bash
# Navigate to deploy/eks directory
cd deploy/eks

# Destroy Koorde deployment
./destroy-eks.sh koorde

# Destroy Chord deployment (if deployed)
./destroy-eks.sh chord
```

This script will:
1. Delete Services (removes load balancers)
2. Delete StatefulSet (removes pods)
3. Delete ConfigMap
4. Delete Namespace

### Delete EKS Cluster (Full Cleanup)

To completely remove the EKS cluster and all resources:

```bash
# First, delete all deployments to remove load balancers
./destroy-eks.sh koorde
./destroy-eks.sh chord

# Wait for load balancers to be fully deleted (important!)
echo "Waiting for load balancers to be deleted..."
sleep 60

# Delete the EKS cluster
eksctl delete cluster --name koorde-cache --region us-west-2
```

> **Important for AWS Learner Lab:**
> - Learner Lab sessions expire after 4 hours
> - Always delete resources before session expires to avoid orphaned resources
> - If the session expires with resources running, start a new session and delete them

### Verify Cleanup

```bash
# Check no resources remain
kubectl get all -n koorde-dht
kubectl get all -n chord-dht

# Verify no load balancers (can incur charges)
aws elbv2 describe-load-balancers --query 'LoadBalancers[*].[LoadBalancerName,State.Code]' --output table

# Verify cluster is deleted
eksctl get cluster --region us-west-2
```

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

