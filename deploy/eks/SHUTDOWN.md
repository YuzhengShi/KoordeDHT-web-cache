# Shutdown Checklist (AWS Learner Lab)

**⏰ Learner Lab sessions expire after 4 hours!**

## Before You Stop

### 1. Save Your Results ✅
```bash
# Export experiment data
kubectl get pods -n koorde-dht -o wide > ~/pod-status.txt
kubectl top pods -n koorde-dht > ~/resource-usage.txt 2>/dev/null || true

# Copy CSVs and logs to local
cp *.csv ~/
cp *.log ~/
```

### 2. Save Deployment Config ✅
```bash
# Backup current state
kubectl get all -n koorde-dht -o yaml > ~/koorde-backup.yaml
kubectl get configmap -n koorde-dht -o yaml > ~/koorde-config-backup.yaml
```

### 3. Note Your ECR Image ✅
```bash
# Remember which image you're using
kubectl get statefulset dht-node -n koorde-dht -o yaml | grep image:
```

## Cleanup Options

### Option A: Keep Cluster Running (Costs $$$)
- ⚠️ **Not recommended for Learner Lab**
- Cluster will keep running and consuming credits
- Next session: Just reconnect and continue

### Option B: Delete Deployments Only (Moderate Costs)
```bash
# Remove pods but keep cluster infrastructure
./deploy/eks/destroy-eks.sh koorde
./deploy/eks/destroy-eks.sh chord
```
- Saves some costs
- Next session: Faster to redeploy
- Cluster creation time saved

### Option C: Delete Everything (Recommended)
```bash
# Complete cleanup
eksctl delete cluster --name koorde-cache --region us-west-2 --wait
```
- ✅ **Recommended for Learner Lab**
- No ongoing costs
- Next session: Full setup required (~20 mins)

## Next Session Checklist

1. ✅ Get new AWS credentials from Learner Lab
2. ✅ Run: `aws configure` (paste new credentials)
3. ✅ Run: `aws configure set aws_session_token <NEW-TOKEN>`
4. ✅ If cluster exists: `aws eks update-kubeconfig --name koorde-cache --region us-west-2`
5. ✅ If cluster deleted: Re-run setup from `COMPLETE_GUIDE.md`

## Quick Commands

```bash
# Check what's running
kubectl get all --all-namespaces

# Full cleanup
eksctl delete cluster --name koorde-cache --region us-west-2 --wait

# Just delete pods
kubectl delete namespace koorde-dht
kubectl delete namespace chord-dht
```
