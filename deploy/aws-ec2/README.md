# AWS EC2 Deployment

This directory contains Terraform scripts to deploy the KoordeDHT cluster to AWS EC2.

## Prerequisites

- Terraform installed.
- AWS Credentials configured (e.g., `aws configure` or environment variables).
- Docker image `flaviosimonelli/koorde-node:latest` must be accessible (e.g., on Docker Hub).

## Usage

1.  **Deploy:**
    ```bash
    ./deploy.sh
    ```
    Or manually:
    ```bash
    terraform init
    terraform apply
    ```

2.  **Configuration:**
    You can override variables using a `terraform.tfvars` file or command line flags.
    - `region`: AWS Region (default: `us-east-1`)
    - `node_count`: Number of nodes (default: `3`)
    - `existing_instance_profile`: Use an existing IAM instance profile (useful for Sandbox environments).

    Example:
    ```bash
    terraform apply -var="existing_instance_profile=AWSReservedSSO_myisb_IsbUsersPS_4122b99934429408"
    ```

3.  **Verify:**
    After deployment, Terraform will output the ALB DNS name.
    ```bash
    curl http://<ALB_DNS_NAME>/health
    ```

## Architecture

- **Auto Scaling Group**: Manages EC2 instances.
- **ALB**: Load balances HTTP traffic to nodes.
- **Route53**: Private hosted zone `koorde.internal` for service discovery.
- **Security Groups**: Restrict traffic to necessary ports.
