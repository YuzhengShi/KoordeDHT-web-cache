#!/bin/bash
#
# Destroy Locust ECS Infrastructure
# Cleans up all resources created by deploy-locust.sh
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

if [ ! -f "locust-config.env" ]; then
    echo "Error: locust-config.env not found. Nothing to destroy."
    exit 1
fi

source locust-config.env

echo "============================================"
echo " Destroying Locust ECS Infrastructure"
echo "============================================"
echo " Cluster: $CLUSTER_NAME"
echo " Region: $REGION"
echo "============================================"
echo ""

read -p "Are you sure you want to destroy all resources? (yes/no): " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
    echo "Aborted."
    exit 0
fi

# Step 1: Stop all tasks
echo "[1/6] Stopping all tasks..."
TASKS=$(aws ecs list-tasks \
    --cluster "$CLUSTER_NAME" \
    --query "taskArns" \
    --output text \
    --region "$REGION" 2>/dev/null || true)

if [ -n "$TASKS" ] && [ "$TASKS" != "None" ]; then
    for TASK in $TASKS; do
        aws ecs stop-task --cluster "$CLUSTER_NAME" --task "$TASK" --region "$REGION" > /dev/null 2>&1 || true
    done
fi
echo "Tasks stopped."

# Step 2: Terminate EC2 instances
echo "[2/6] Terminating EC2 instances..."
ALL_INSTANCES="$MASTER_INSTANCE_ID $WORKER_INSTANCE_IDS"

if [ -n "$ALL_INSTANCES" ]; then
    aws ec2 terminate-instances \
        --instance-ids $ALL_INSTANCES \
        --region "$REGION" > /dev/null 2>&1 || true
    
    echo "Waiting for instances to terminate..."
    aws ec2 wait instance-terminated \
        --instance-ids $ALL_INSTANCES \
        --region "$REGION" 2>/dev/null || true
fi
echo "Instances terminated."

# Step 3: Deregister task definitions
echo "[3/6] Deregistering task definitions..."
for FAMILY in locust-master locust-worker; do
    TASK_DEFS=$(aws ecs list-task-definitions \
        --family-prefix "$FAMILY" \
        --query "taskDefinitionArns" \
        --output text \
        --region "$REGION" 2>/dev/null || true)
    
    if [ -n "$TASK_DEFS" ] && [ "$TASK_DEFS" != "None" ]; then
        for TD in $TASK_DEFS; do
            aws ecs deregister-task-definition \
                --task-definition "$TD" \
                --region "$REGION" > /dev/null 2>&1 || true
        done
    fi
done
echo "Task definitions deregistered."

# Step 4: Delete ECS cluster
echo "[4/6] Deleting ECS cluster..."
aws ecs delete-cluster \
    --cluster "$CLUSTER_NAME" \
    --region "$REGION" > /dev/null 2>&1 || true
echo "Cluster deleted."

# Step 5: Delete security group (may take a moment)
echo "[5/6] Deleting security group..."
sleep 10  # Wait for ENIs to be released
aws ec2 delete-security-group \
    --group-id "$SECURITY_GROUP_ID" \
    --region "$REGION" 2>/dev/null || echo "Security group may still be in use, delete manually later."

# Step 6: Delete ECR repository (optional)
read -p "Delete ECR repository (locust-dht)? (yes/no): " DELETE_ECR
if [ "$DELETE_ECR" == "yes" ]; then
    aws ecr delete-repository \
        --repository-name "locust-dht" \
        --force \
        --region "$REGION" > /dev/null 2>&1 || true
    echo "ECR repository deleted."
fi

# Clean up config file
rm -f locust-config.env

echo ""
echo "============================================"
echo " Cleanup Complete!"
echo "============================================"
echo ""
echo "All Locust ECS resources have been destroyed."
echo ""

