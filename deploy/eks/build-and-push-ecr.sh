#!/bin/bash
set -euo pipefail

# Configuration
REGION="us-west-2"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REPO_NAME="koorde-node"
IMAGE_TAG="latest"

echo "AWS Account ID: ${ACCOUNT_ID}"
echo "Region: ${REGION}"
echo "Repository: ${REPO_NAME}"

# Change to project root (2 levels up from deploy/eks)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
cd "${PROJECT_ROOT}"
echo "Building from: $(pwd)"
echo ""

# Step 1: Create ECR repository (if it doesn't exist)
echo "Creating ECR repository..."
aws ecr create-repository \
  --repository-name ${REPO_NAME} \
  --region ${REGION} \
  --image-scanning-configuration scanOnPush=true \
  2>/dev/null || echo "Repository already exists"

# Step 2: Authenticate Docker to ECR
echo "Authenticating Docker to ECR..."
aws ecr get-login-password --region ${REGION} | \
  docker login --username AWS --password-stdin ${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com

# Step 3: Build the Docker image
echo "Building Docker image..."
docker build \
  -f docker/node.Dockerfile \
  -t ${REPO_NAME}:${IMAGE_TAG} \
  .

# Step 4: Tag the image for ECR
ECR_URI="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${REPO_NAME}:${IMAGE_TAG}"
echo "Tagging image as: ${ECR_URI}"
docker tag ${REPO_NAME}:${IMAGE_TAG} ${ECR_URI}

# Step 5: Push to ECR
echo "Pushing image to ECR..."
docker push ${ECR_URI}

echo ""
echo "✓ Docker image successfully pushed to ECR!"
echo "Image URI: ${ECR_URI}"
echo ""
echo "Update your StatefulSet with:"
echo "  image: ${ECR_URI}"
