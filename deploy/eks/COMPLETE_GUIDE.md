# Complete Deployment Guide (AWS Learner Lab)

This guide covers the **complete workflow** for deploying your custom Koorde/Chord implementation to AWS EKS using the Learner Lab.

## ⏱️ Time Required
- **First-time setup:** ~30 minutes
- **Subsequent deployments:** ~10 minutes
- **AWS Learner Lab session:** 4 hours max

---

## 1️⃣ Setup (One-Time)

### Step 1: Start AWS Learner Lab
1. Go to your learning platform
2. Start the AWS Learner Lab
3. Click **AWS Details** → **Show** next to "AWS CLI"
4. Copy the credentials

### Step 2: Configure AWS CLI
```bash
# Set up virtual environment (recommended)
python3 -m venv ~/eks-tools-env
source ~/eks-tools-env/bin/activate

# Install AWS CLI
pip install awscli

# Configure credentials (paste from AWS Details)
aws configure
# Region: us-west-2
# Output: json

# Set session token
aws configure set aws_session_token <YOUR-SESSION-TOKEN>

# Verify
aws sts get-caller-identity
```

### Step 3: Install EKS Tools
```bash
# Create bin directory
mkdir -p ~/eks-tools-env/bin

# Install eksctl
curl -sL "https://github.com/weaveworks/eksctl/releases/latest/download/eksctl_$(uname -s)_amd64.tar.gz" | tar xz -C ~/eks-tools-env/bin/

# Install kubectl
curl -sLO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x kubectl
mv kubectl ~/eks-tools-env/bin/

# Install Helm
curl -s https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# Verify
eksctl version
kubectl version --client
```

### Step 4: Create EKS Cluster
```bash
cd /path/to/KoordeDHT-web-cache/deploy/eks

# Create cluster (15-20 mins)
eksctl create cluster -f cluster-config.yaml

# If creation fails, clean up first:
aws cloudformation update-termination-protection \
  --stack-name eksctl-koorde-cache-cluster \
  --region us-west-2 \
  --no-enable-termination-protection
  
aws cloudformation delete-stack \
  --stack-name eksctl-koorde-cache-cluster \
  --region us-west-2
```

### Step 5: Install Load Balancer Controller
```bash
# Add Helm repo
helm repo add eks https://aws.github.io/eks-charts
helm repo update

# Install
helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=koorde-cache \
  --set serviceAccount.create=false \
  --set serviceAccount.name=default
```

---

## 2️⃣ Build & Deploy Your Code

### Step 1: Build Docker Image
```bash
cd /path/to/KoordeDHT-web-cache

# Build and push to ECR
./deploy/eks/build-and-push-ecr.sh

# Note the output ECR URI
# Example: 007438440430.dkr.ecr.us-west-2.amazonaws.com/koorde-node:latest
```

### Step 2: Update StatefulSet
Edit `deploy/eks/statefulset.yaml` line 21:
```yaml
image: YOUR-ECR-URI-HERE  # Replace with actual ECR URI from Step 1
```

**IMPORTANT:** Also ensure `service-cache.yaml` has:
```yaml
service.beta.kubernetes.io/aws-load-balancer-scheme: "internet-facing"
```
(This makes the Load Balancer publicly accessible - required for Learner Lab)

### Step 3: Deploy
```bash
cd deploy/eks

# Deploy Koorde
./deploy-eks.sh koorde

# (Optional) Deploy Chord
./deploy-eks.sh chord
```

### Step 4: Verify
```bash
# Check pods
kubectl get pods -n koorde-dht

# All pods should show 1/1 READY after ~30 seconds
```

---

## 3️⃣ Testing Your Deployment

### Method 1: Port Forward (Recommended for Learner Lab)
```bash
# Forward port from pod to localhost
kubectl port-forward -n koorde-dht dht-node-0 8080:8080
```

In a new terminal:
```bash
# Health check
curl http://localhost:8080/health

# Test cache
curl "http://localhost:8080/cache?url=https://httpbin.org/json"

# Check metrics
curl http://localhost:8080/metrics | jq
```

### Method 2: Load Balancer (If Accessible)
```bash
# Get LB URL
kubectl get svc dht-cache-http -n koorde-dht

# Test (may timeout due to Learner Lab restrictions)
curl "http://<LB-URL>/cache?url=https://httpbin.org/json"
```

---

## 4️⃣ Running Experiments

### Scale Cluster
```bash
# Scale to 50 nodes
kubectl scale statefulset dht-node -n koorde-dht --replicas=50

# Watch scaling
kubectl get pods -n koorde-dht -w
```

### Run Workload
```bash
# Build workload generator
cd /path/to/KoordeDHT-web-cache
go build -o cache-workload ./cmd/cache-workload

# Run test (use port-forward in another terminal)
./cache-workload \
  --target http://localhost:8080 \
  --requests 10000 \
  --urls 1000 \
  --rate 100 \
  --output results-koorde.csv
```

---

## 🛑 Before Stopping (IMPORTANT!)

**AWS Learner Lab sessions only last 4 hours.** Save your work before the session expires:

### Save Configuration
```bash
# Export current deployment state
kubectl get all -n koorde-dht -o yaml > ~/koorde-deployment-backup.yaml
kubectl get all -n chord-dht -o yaml > ~/chord-deployment-backup.yaml 2>/dev/null || true
```

### Save Results
```bash
# Copy benchmark results to local machine
scp *.csv your-laptop:/local/path/
```

### Cleanup (Optional - Saves Costs)
```bash
# Delete deployments but keep cluster
./deploy/eks/destroy-eks.sh koorde
./deploy/eks/destroy-eks.sh chord

# OR delete entire cluster
eksctl delete cluster --name koorde-cache --region us-west-2
```

---

## 🔄 Next Session

When you start a new Learner Lab session:

1. **Update AWS credentials** (they change each session)
   ```bash
   source ~/eks-tools-env/bin/activate
   aws configure  # Paste new credentials
   aws configure set aws_session_token <NEW-TOKEN>
   ```

2. **Update kubeconfig**
   ```bash
   aws eks update-kubeconfig --name koorde-cache --region us-west-2
   ```

3. **Verify cluster**
   ```bash
   kubectl get nodes
   ```

4. **Redeploy** (if you deleted deployments)
   ```bash
   cd /path/to/KoordeDHT-web-cache/deploy/eks
   ./deploy-eks.sh koorde
   ```

---

## 🐛 Troubleshooting

### Pods CrashLoopBackOff
```bash
# Check logs
kubectl logs dht-node-0 -n koorde-dht

# Common fix: Delete and restart
kubectl delete pods -l app=dht-node -n koorde-dht
```

### Can't Connect to Cluster
```bash
# Update kubeconfig
aws eks update-kubeconfig --name koorde-cache --region us-west-2
```

### ECR Push Fails
```bash
# Re-authenticate Docker
aws ecr get-login-password --region us-west-2 | \
  docker login --username AWS --password-stdin \
  $(aws sts get-caller-identity --query Account --output text).dkr.ecr.us-west-2.amazonaws.com
```
