#!/bin/bash
set -e

echo "Deploying KoordeDHT to AWS EC2..."

# Check for Terraform
if ! command -v terraform &> /dev/null; then
    echo "Terraform could not be found. Please install it."
    exit 1
fi

cd "$(dirname "$0")"

# Initialize Terraform
echo "Initializing Terraform..."
terraform init

# Apply Terraform
echo "Applying Terraform configuration..."
terraform apply
