#!/bin/bash
#
# Start Locust Load Test on ECS
#
# Usage:
#   ./start-locust.sh <TARGET_URL> [--protocol koorde|chord] [--users N] [--spawn-rate N] [--duration Nm]
#
# Example:
#   ./start-locust.sh http://your-lb.elb.amazonaws.com --protocol koorde --users 100 --duration 5m
#

set -euo pipefail

# Load configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

if [ ! -f "locust-config.env" ]; then
    echo "Error: locust-config.env not found. Run deploy-locust.sh first."
    exit 1
fi

source locust-config.env

# Default parameters
TARGET_URL=""
PROTOCOL="DHT"
USERS=100
SPAWN_RATE=10
DURATION=""
URL_POOL_SIZE=100

# Parse arguments
if [ $# -lt 1 ]; then
    echo "Usage: $0 <TARGET_URL> [options]"
    echo ""
    echo "Options:"
    echo "  --protocol NAME    Protocol name: koorde or chord (default: DHT)"
    echo "  --users N          Number of users (default: 100)"
    echo "  --spawn-rate N     Spawn rate per second (default: 10)"
    echo "  --duration Nm      Test duration, e.g., 5m (default: run until stopped)"
    echo "  --url-pool N       URL pool size (default: 100)"
    echo ""
    echo "Example:"
    echo "  $0 http://koorde-lb.amazonaws.com --protocol koorde --users 200 --duration 5m"
    exit 1
fi

TARGET_URL="$1"
shift

while [[ $# -gt 0 ]]; do
    case $1 in
        --protocol)
            PROTOCOL="$2"
            shift 2
            ;;
        --users)
            USERS="$2"
            shift 2
            ;;
        --spawn-rate)
            SPAWN_RATE="$2"
            shift 2
            ;;
        --duration)
            DURATION="$2"
            shift 2
            ;;
        --url-pool)
            URL_POOL_SIZE="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

echo "============================================"
echo " Starting Locust Load Test"
echo "============================================"
echo " Target URL: $TARGET_URL"
echo " Protocol: $PROTOCOL"
echo " Users: $USERS"
echo " Spawn Rate: $SPAWN_RATE/sec"
echo " Duration: ${DURATION:-unlimited}"
echo " URL Pool: $URL_POOL_SIZE"
echo " Master IP: $MASTER_PRIVATE_IP"
echo "============================================"
echo ""

ACCOUNT_ID="149740719999"
ECR_IMAGE="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/locust-dht:latest"

# Register master task definition with bridge network mode
echo "Registering master task definition..."
aws ecs register-task-definition \
    --family "locust-master" \
    --network-mode "bridge" \
    --requires-compatibilities "EC2" \
    --execution-role-arn "arn:aws:iam::${ACCOUNT_ID}:role/LabRole" \
    --task-role-arn "arn:aws:iam::${ACCOUNT_ID}:role/LabRole" \
    --container-definitions "[{\"name\":\"locust-master\",\"image\":\"${ECR_IMAGE}\",\"essential\":true,\"memory\":1024,\"portMappings\":[{\"containerPort\":8089,\"hostPort\":8089,\"protocol\":\"tcp\"},{\"containerPort\":5557,\"hostPort\":5557,\"protocol\":\"tcp\"}],\"command\":[\"-f\",\"/mnt/locust/locustfile.py\",\"--master\",\"--host\",\"${TARGET_URL}\"],\"environment\":[{\"name\":\"PROTOCOL\",\"value\":\"${PROTOCOL}\"},{\"name\":\"URL_POOL_SIZE\",\"value\":\"${URL_POOL_SIZE}\"}],\"logConfiguration\":{\"logDriver\":\"awslogs\",\"options\":{\"awslogs-group\":\"/ecs/locust-dht\",\"awslogs-region\":\"${REGION}\",\"awslogs-stream-prefix\":\"master\",\"awslogs-create-group\":\"true\"}}}]" \
    --region "$REGION" > /dev/null

echo "Master task definition registered"

# Register worker task definition with bridge network mode
echo "Registering worker task definition..."
aws ecs register-task-definition \
    --family "locust-worker" \
    --network-mode "bridge" \
    --requires-compatibilities "EC2" \
    --execution-role-arn "arn:aws:iam::${ACCOUNT_ID}:role/LabRole" \
    --task-role-arn "arn:aws:iam::${ACCOUNT_ID}:role/LabRole" \
    --container-definitions "[{\"name\":\"locust-worker\",\"image\":\"${ECR_IMAGE}\",\"essential\":true,\"memory\":1024,\"command\":[\"-f\",\"/mnt/locust/locustfile.py\",\"--worker\",\"--master-host\",\"${MASTER_PRIVATE_IP}\"],\"environment\":[{\"name\":\"PROTOCOL\",\"value\":\"${PROTOCOL}\"},{\"name\":\"URL_POOL_SIZE\",\"value\":\"${URL_POOL_SIZE}\"}],\"logConfiguration\":{\"logDriver\":\"awslogs\",\"options\":{\"awslogs-group\":\"/ecs/locust-dht\",\"awslogs-region\":\"${REGION}\",\"awslogs-stream-prefix\":\"worker\",\"awslogs-create-group\":\"true\"}}}]" \
    --region "$REGION" > /dev/null

echo "Worker task definition registered"

# Get container instance ARNs
echo "Getting container instances..."
CONTAINER_INSTANCES=$(aws ecs list-container-instances \
    --cluster "$CLUSTER_NAME" \
    --query "containerInstanceArns" \
    --output text \
    --region "$REGION")

if [ -z "$CONTAINER_INSTANCES" ]; then
    echo "Error: No container instances registered. Wait a few minutes and try again."
    exit 1
fi

INSTANCE_COUNT=$(echo "$CONTAINER_INSTANCES" | wc -w)
echo "Found $INSTANCE_COUNT container instances"

# Find container instance ARN for master EC2 instance
echo "Finding master container instance..."
MASTER_CONTAINER_INSTANCE=""
for CI_ARN in $CONTAINER_INSTANCES; do
    CI_EC2_ID=$(aws ecs describe-container-instances \
        --cluster "$CLUSTER_NAME" \
        --container-instances "$CI_ARN" \
        --query "containerInstances[0].ec2InstanceId" \
        --output text \
        --region "$REGION")
    
    if [ "$CI_EC2_ID" == "$MASTER_INSTANCE_ID" ]; then
        MASTER_CONTAINER_INSTANCE="$CI_ARN"
        echo "Found master container instance: $CI_ARN"
        break
    fi
done

if [ -z "$MASTER_CONTAINER_INSTANCE" ]; then
    echo "Warning: Could not find master container instance, using first available"
    MASTER_CONTAINER_INSTANCE=$(echo "$CONTAINER_INSTANCES" | awk '{print $1}')
fi

# Stop any existing tasks
echo "Stopping existing tasks..."
EXISTING_TASKS=$(aws ecs list-tasks \
    --cluster "$CLUSTER_NAME" \
    --query "taskArns" \
    --output text \
    --region "$REGION" 2>/dev/null || true)

if [ -n "$EXISTING_TASKS" ] && [ "$EXISTING_TASKS" != "None" ]; then
    for TASK in $EXISTING_TASKS; do
        aws ecs stop-task --cluster "$CLUSTER_NAME" --task "$TASK" --region "$REGION" > /dev/null 2>&1 || true
    done
    echo "Stopped existing tasks"
    sleep 5
fi

# Run master task on specific container instance
echo "Starting master task on master instance..."
MASTER_TASK_ARN=$(aws ecs start-task \
    --cluster "$CLUSTER_NAME" \
    --task-definition "locust-master" \
    --container-instances "$MASTER_CONTAINER_INSTANCE" \
    --query "tasks[0].taskArn" \
    --output text \
    --region "$REGION")

echo "Master task started: $MASTER_TASK_ARN"

# Wait for master to be running
echo "Waiting for master to start..."
sleep 15

# Calculate worker count
WORKER_COUNT=$((INSTANCE_COUNT - 1))
if [ "$WORKER_COUNT" -lt 1 ]; then
    WORKER_COUNT=1
fi

# Run worker tasks (ECS will schedule them on available instances)
echo "Starting $WORKER_COUNT worker tasks..."
aws ecs run-task \
    --cluster "$CLUSTER_NAME" \
    --task-definition "locust-worker" \
    --count "$WORKER_COUNT" \
    --launch-type "EC2" \
    --region "$REGION" > /dev/null

echo ""
echo "============================================"
echo " Locust Test Started!"
echo "============================================"
echo ""
echo " Master: 1 task (on $MASTER_PRIVATE_IP)"
echo " Workers: $WORKER_COUNT tasks"
echo ""
echo " Access Locust Web UI:"
echo "   http://$MASTER_PUBLIC_IP:8089"
echo ""
echo " To view logs:"
echo "   aws logs tail /ecs/locust-dht --follow --region $REGION"
echo ""
echo " To stop the test:"
echo "   ./stop-locust.sh"
echo ""
