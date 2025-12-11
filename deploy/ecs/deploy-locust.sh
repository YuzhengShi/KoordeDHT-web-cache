#!/bin/bash
#
# Deploy Locust Load Testing Infrastructure on AWS ECS with EC2
# Uses existing LabRole IAM role
#
# Usage:
#   ./deploy-locust.sh [--workers N] [--region REGION]
#
# Example:
#   ./deploy-locust.sh --workers 4 --region us-west-2
#

set -euo pipefail

# Configuration
REGION="${AWS_REGION:-us-west-2}"
ACCOUNT_ID="149740719999"
CLUSTER_NAME="locust-cluster"
ECR_REPO="locust-dht"
WORKER_COUNT=4
INSTANCE_TYPE="t3.large"
KEY_NAME=""  # Set if you want SSH access

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --workers)
            WORKER_COUNT="$2"
            shift 2
            ;;
        --region)
            REGION="$2"
            shift 2
            ;;
        --key-name)
            KEY_NAME="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "============================================"
echo " Deploying Locust on ECS"
echo "============================================"
echo " Region: $REGION"
echo " Account: $ACCOUNT_ID"
echo " Workers: $WORKER_COUNT"
echo " Instance Type: $INSTANCE_TYPE"
echo "============================================"
echo ""

# Step 1: Create ECR Repository
echo "[1/8] Creating ECR repository..."
aws ecr create-repository \
    --repository-name "$ECR_REPO" \
    --region "$REGION" \
    2>/dev/null || echo "Repository already exists"

# Step 2: Build and Push Docker Image
echo "[2/8] Building and pushing Docker image..."
ECR_URI="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${ECR_REPO}:latest"

aws ecr get-login-password --region "$REGION" | \
    docker login --username AWS --password-stdin "${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"

docker build -t "$ECR_REPO:latest" .
docker tag "$ECR_REPO:latest" "$ECR_URI"
docker push "$ECR_URI"

echo "Image pushed: $ECR_URI"

# Step 3: Create CloudWatch Log Group
echo "[3/8] Creating CloudWatch log group..."
aws logs create-log-group \
    --log-group-name "/ecs/locust-dht" \
    --region "$REGION" \
    2>/dev/null || echo "Log group already exists"

# Step 4: Create ECS Cluster
echo "[4/8] Creating ECS cluster..."
aws ecs create-cluster \
    --cluster-name "$CLUSTER_NAME" \
    --region "$REGION" \
    2>/dev/null || echo "Cluster already exists"

# Step 5: Get default VPC and Subnets
echo "[5/8] Getting VPC configuration..."
VPC_ID=$(aws ec2 describe-vpcs \
    --filters "Name=isDefault,Values=true" \
    --query "Vpcs[0].VpcId" \
    --output text \
    --region "$REGION")

SUBNET_IDS=$(aws ec2 describe-subnets \
    --filters "Name=vpc-id,Values=$VPC_ID" \
    --query "Subnets[0:2].SubnetId" \
    --output text \
    --region "$REGION" | tr '\t' ',')

FIRST_SUBNET=$(echo "$SUBNET_IDS" | cut -d',' -f1)

echo "VPC: $VPC_ID"
echo "Subnets: $SUBNET_IDS"

# Step 6: Create Security Group
echo "[6/8] Creating security group..."
SG_NAME="locust-ecs-sg"

# Check if security group exists
SG_ID=$(aws ec2 describe-security-groups \
    --filters "Name=group-name,Values=$SG_NAME" "Name=vpc-id,Values=$VPC_ID" \
    --query "SecurityGroups[0].GroupId" \
    --output text \
    --region "$REGION" 2>/dev/null || echo "None")

if [ "$SG_ID" == "None" ] || [ -z "$SG_ID" ]; then
    SG_ID=$(aws ec2 create-security-group \
        --group-name "$SG_NAME" \
        --description "Security group for Locust ECS" \
        --vpc-id "$VPC_ID" \
        --query "GroupId" \
        --output text \
        --region "$REGION")
    
    # Add inbound rules
    aws ec2 authorize-security-group-ingress \
        --group-id "$SG_ID" \
        --protocol tcp --port 8089 --cidr 0.0.0.0/0 \
        --region "$REGION" 2>/dev/null || true
    
    aws ec2 authorize-security-group-ingress \
        --group-id "$SG_ID" \
        --protocol tcp --port 5557 --cidr 0.0.0.0/0 \
        --region "$REGION" 2>/dev/null || true
    
    aws ec2 authorize-security-group-ingress \
        --group-id "$SG_ID" \
        --protocol tcp --port 22 --cidr 0.0.0.0/0 \
        --region "$REGION" 2>/dev/null || true
    
    # Allow all traffic within the security group
    aws ec2 authorize-security-group-ingress \
        --group-id "$SG_ID" \
        --protocol -1 --source-group "$SG_ID" \
        --region "$REGION" 2>/dev/null || true
fi

echo "Security Group: $SG_ID"

# Step 7: Register Task Definitions (using bridge network mode for simplicity)
echo "[7/8] Registering task definitions..."

# Register master task definition with bridge network mode
aws ecs register-task-definition \
    --family "locust-master" \
    --network-mode "bridge" \
    --requires-compatibilities "EC2" \
    --execution-role-arn "arn:aws:iam::${ACCOUNT_ID}:role/LabRole" \
    --task-role-arn "arn:aws:iam::${ACCOUNT_ID}:role/LabRole" \
    --container-definitions "[{\"name\":\"locust-master\",\"image\":\"${ECR_URI}\",\"essential\":true,\"memory\":1024,\"portMappings\":[{\"containerPort\":8089,\"hostPort\":8089,\"protocol\":\"tcp\"},{\"containerPort\":5557,\"hostPort\":5557,\"protocol\":\"tcp\"}],\"command\":[\"-f\",\"/mnt/locust/locustfile.py\",\"--master\"],\"environment\":[{\"name\":\"PROTOCOL\",\"value\":\"DHT\"},{\"name\":\"URL_POOL_SIZE\",\"value\":\"100\"}],\"logConfiguration\":{\"logDriver\":\"awslogs\",\"options\":{\"awslogs-group\":\"/ecs/locust-dht\",\"awslogs-region\":\"${REGION}\",\"awslogs-stream-prefix\":\"master\",\"awslogs-create-group\":\"true\"}}}]" \
    --region "$REGION" > /dev/null

echo "Registered locust-master task definition"

# Step 8: Launch EC2 instances for ECS
echo "[8/8] Launching EC2 instances..."

# Get latest ECS-optimized AMI using EC2 describe-images (more reliable)
ECS_AMI=$(aws ec2 describe-images \
    --owners amazon \
    --filters "Name=name,Values=amzn2-ami-ecs-hvm-*-x86_64-ebs" \
              "Name=state,Values=available" \
    --query "sort_by(Images, &CreationDate)[-1].ImageId" \
    --output text \
    --region "$REGION")

# Fallback to known working AMI if query fails
if [ -z "$ECS_AMI" ] || [ "$ECS_AMI" == "None" ]; then
    echo "Warning: Could not find ECS AMI, using fallback for us-west-2"
    # ECS-optimized Amazon Linux 2 AMI for us-west-2 (updated regularly)
    ECS_AMI="ami-0e3e2573af0e1cc0e"
fi

echo "Using ECS AMI: $ECS_AMI"

# User data script to join ECS cluster
USER_DATA=$(cat <<EOF | base64 -w 0
#!/bin/bash
echo "ECS_CLUSTER=$CLUSTER_NAME" >> /etc/ecs/ecs.config
echo "ECS_ENABLE_TASK_IAM_ROLE=true" >> /etc/ecs/ecs.config
EOF
)

# Create IAM instance profile if needed (using LabRole)
aws iam create-instance-profile \
    --instance-profile-name LabInstanceProfile \
    2>/dev/null || true

aws iam add-role-to-instance-profile \
    --instance-profile-name LabInstanceProfile \
    --role-name LabRole \
    2>/dev/null || true

# Wait for instance profile to be ready
sleep 5

# Launch master instance
MASTER_INSTANCE_ARGS=(
    --image-id "$ECS_AMI"
    --instance-type "$INSTANCE_TYPE"
    --subnet-id "$FIRST_SUBNET"
    --security-group-ids "$SG_ID"
    --iam-instance-profile "Name=LabInstanceProfile"
    --user-data "$USER_DATA"
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=locust-master},{Key=Role,Value=master}]"
    --region "$REGION"
)

if [ -n "$KEY_NAME" ]; then
    MASTER_INSTANCE_ARGS+=(--key-name "$KEY_NAME")
fi

MASTER_INSTANCE_ID=$(aws ec2 run-instances \
    "${MASTER_INSTANCE_ARGS[@]}" \
    --query "Instances[0].InstanceId" \
    --output text)

echo "Launched master instance: $MASTER_INSTANCE_ID"

# Launch worker instances
WORKER_INSTANCE_ARGS=(
    --image-id "$ECS_AMI"
    --instance-type "$INSTANCE_TYPE"
    --count "$WORKER_COUNT"
    --subnet-id "$FIRST_SUBNET"
    --security-group-ids "$SG_ID"
    --iam-instance-profile "Name=LabInstanceProfile"
    --user-data "$USER_DATA"
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=locust-worker},{Key=Role,Value=worker}]"
    --region "$REGION"
)

if [ -n "$KEY_NAME" ]; then
    WORKER_INSTANCE_ARGS+=(--key-name "$KEY_NAME")
fi

WORKER_INSTANCE_IDS=$(aws ec2 run-instances \
    "${WORKER_INSTANCE_ARGS[@]}" \
    --query "Instances[*].InstanceId" \
    --output text)

echo "Launched worker instances: $WORKER_INSTANCE_IDS"

# Wait for instances to be running
echo ""
echo "Waiting for instances to be running..."
aws ec2 wait instance-running \
    --instance-ids $MASTER_INSTANCE_ID $WORKER_INSTANCE_IDS \
    --region "$REGION"

# Get master private IP
MASTER_PRIVATE_IP=$(aws ec2 describe-instances \
    --instance-ids "$MASTER_INSTANCE_ID" \
    --query "Reservations[0].Instances[0].PrivateIpAddress" \
    --output text \
    --region "$REGION")

MASTER_PUBLIC_IP=$(aws ec2 describe-instances \
    --instance-ids "$MASTER_INSTANCE_ID" \
    --query "Reservations[0].Instances[0].PublicIpAddress" \
    --output text \
    --region "$REGION")

echo ""
echo "Master Private IP: $MASTER_PRIVATE_IP"
echo "Master Public IP: $MASTER_PUBLIC_IP"

# Wait for ECS agent to register instances
echo ""
echo "Waiting for ECS agents to register (this may take 2-3 minutes)..."
sleep 60

# Check registered container instances
CONTAINER_INSTANCES=$(aws ecs list-container-instances \
    --cluster "$CLUSTER_NAME" \
    --query "containerInstanceArns" \
    --output text \
    --region "$REGION")

echo "Registered container instances: $CONTAINER_INSTANCES"

# Save configuration for later use
cat > locust-config.env << EOF
# Locust ECS Configuration
# Generated on $(date)
REGION=$REGION
CLUSTER_NAME=$CLUSTER_NAME
MASTER_INSTANCE_ID=$MASTER_INSTANCE_ID
MASTER_PRIVATE_IP=$MASTER_PRIVATE_IP
MASTER_PUBLIC_IP=$MASTER_PUBLIC_IP
WORKER_INSTANCE_IDS="$WORKER_INSTANCE_IDS"
SECURITY_GROUP_ID=$SG_ID
VPC_ID=$VPC_ID
SUBNET_IDS=$SUBNET_IDS
EOF

echo ""
echo "============================================"
echo " Deployment Complete!"
echo "============================================"
echo ""
echo "Master Instance: $MASTER_INSTANCE_ID"
echo "Master Public IP: $MASTER_PUBLIC_IP"
echo "Worker Instances: $WORKER_INSTANCE_IDS"
echo ""
echo "Configuration saved to: locust-config.env"
echo ""
echo "Next steps:"
echo "  1. Wait 2-3 minutes for ECS agents to fully register"
echo "  2. Run the start script to launch Locust:"
echo "     ./start-locust.sh <TARGET_URL>"
echo ""
echo "  Example:"
echo "     ./start-locust.sh http://your-koorde-lb.elb.amazonaws.com"
echo ""
echo "  Access Locust Web UI at:"
echo "     http://$MASTER_PUBLIC_IP:8089"
echo ""

