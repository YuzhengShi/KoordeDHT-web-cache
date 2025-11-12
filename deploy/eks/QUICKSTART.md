# EKS Quick Start Guide

Get KoordeDHT-Web-Cache running on AWS EKS in 10 minutes.

## Step-by-Step

### 1. Create EKS Cluster (5 minutes)

```bash
eksctl create cluster \
  --name koorde-cache \
  --region us-east-1 \
  --nodegroup-name standard \
  --node-type t3.medium \
  --nodes 3 \
  --managed
```

### 2. Install AWS Load Balancer Controller (2 minutes)

```bash
# Associate OIDC provider
eksctl utils associate-iam-oidc-provider \
  --cluster koorde-cache \
  --approve

# Install with Helm
helm repo add eks https://aws.github.io/eks-charts
helm repo update

helm install aws-load-balancer-controller \
  eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=koorde-cache
```

### 3. Deploy Koorde (2 minutes)

```bash
cd deploy/eks

# Option A: Use deployment script (recommended)
./deploy-eks.sh

# Option B: Manual deployment
kubectl apply -f namespace.yaml
kubectl apply -f configmap.yaml
kubectl apply -f statefulset.yaml
kubectl apply -f service-headless.yaml
kubectl apply -f service-cache.yaml
```

### 4. Wait for Load Balancer (1 minute)

```bash
kubectl get svc -n koorde-cache -w
# Wait for EXTERNAL-IP to appear
```

### 5. Test Cache (30 seconds)

```bash
# Get load balancer URL
LB=$(kubectl get svc koorde-cache-http -n koorde-cache \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

# Test cache
curl "http://${LB}/cache?url=https://httpbin.org/json"

# Check metrics
curl "http://${LB}/metrics" | jq '.cache'
```

## Done!

You now have a production-ready distributed web cache running on Kubernetes.

## Next Steps

- **Scale up**: `kubectl scale statefulset koorde-node --replicas=20 -n koorde-cache`
- **Enable autoscaling**: `kubectl apply -f hpa.yaml`
- **Add monitoring**: Deploy Prometheus ServiceMonitor
- **Enable TLS**: Configure Ingress with ACM certificate
- **Load test**: Run workload generator

## Clean Up

```bash
./destroy-eks.sh

# Or delete cluster entirely
eksctl delete cluster --name koorde-cache --region us-east-1
```

## Troubleshooting

**Pods pending**: Check node capacity with `kubectl get nodes`
**Load balancer not ready**: Check AWS LB Controller logs
**Health checks failing**: View pod logs with `kubectl logs koorde-node-0`

## Cost

Running 10 pods on 3 t3.medium nodes: **~$200/month**

Stop cluster when not in use to save costs.

