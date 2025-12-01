# Setting Up Virtual Environment for EKS Tools

This guide explains how to set up a clean, isolated environment for your EKS tools (AWS CLI, eksctl, kubectl, Helm) using Python virtual environments. This is highly recommended for AWS Learner Lab users to avoid system conflicts.

## 1. Create and Activate Virtual Environment

```bash
# Install Python and virtualenv (if not already installed)
# Amazon Linux:
sudo yum install -y python3 python3-pip
# Ubuntu:
# sudo apt update && sudo apt install -y python3 python3-pip python3-venv

# Create virtual environment
python3 -m venv ~/eks-tools-env

# Activate the virtual environment
source ~/eks-tools-env/bin/activate

# Your prompt should change to show (eks-tools-env)
```

## 2. Install AWS CLI

```bash
# Make sure you're in the virtual environment
source ~/eks-tools-env/bin/activate

# Install AWS CLI
pip install awscli

# Verify installation
aws --version

# Configure with your Learner Lab credentials
aws configure
# Enter Access Key ID, Secret Access Key, region (us-west-2), output (json)

# Set session token (copy from AWS Details page)
aws configure set aws_session_token <YOUR-SESSION-TOKEN>
```

## 3. Install EKS Tools (eksctl, kubectl, Helm)

We will install these binaries directly into the virtual environment's `bin` directory.

```bash
# Create bin directory
mkdir -p ~/eks-tools-env/bin

# Install eksctl
curl --silent --location "https://github.com/weaveworks/eksctl/releases/latest/download/eksctl_$(uname -s)_amd64.tar.gz" | tar xz -C ~/eks-tools-env/bin/

# Install kubectl
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x kubectl
mv kubectl ~/eks-tools-env/bin/

# Install Helm
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
# If helm installs to /usr/local/bin, copy it:
cp /usr/local/bin/helm ~/eks-tools-env/bin/ 2>/dev/null || true

# Add venv bin to PATH (persists for this venv)
echo 'export PATH="$VIRTUAL_ENV/bin:$PATH"' >> ~/eks-tools-env/bin/activate

# Reactivate to pick up changes
deactivate
source ~/eks-tools-env/bin/activate

# Verify
eksctl version
kubectl version --client
helm version
```

## 4. Automated Setup Script

You can use this script to automate the entire setup:

```bash
cat > ~/setup-eks-venv.sh << 'EOF'
#!/bin/bash
set -e

echo "Setting up EKS tools virtual environment..."

# Create virtual environment
python3 -m venv ~/eks-tools-env
source ~/eks-tools-env/bin/activate

# Install AWS CLI
pip install -q awscli

# Install binary tools
mkdir -p ~/eks-tools-env/bin
echo "Installing eksctl..."
curl -s --location "https://github.com/weaveworks/eksctl/releases/latest/download/eksctl_$(uname -s)_amd64.tar.gz" | tar xz -C ~/eks-tools-env/bin/

echo "Installing kubectl..."
curl -s -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x kubectl
mv kubectl ~/eks-tools-env/bin/

echo "Installing Helm..."
curl -s https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
cp /usr/local/bin/helm ~/eks-tools-env/bin/ 2>/dev/null || true

# Update PATH in activate script
echo 'export PATH="$VIRTUAL_ENV/bin:$PATH"' >> ~/eks-tools-env/bin/activate

echo ""
echo "Virtual environment setup complete!"
echo "To activate: source ~/eks-tools-env/bin/activate"
echo "Then configure AWS: aws configure"
EOF

chmod +x ~/setup-eks-venv.sh
./setup-eks-venv.sh
```

## 5. Daily Usage

Whenever you work on this project:

```bash
# 1. Activate environment
source ~/eks-tools-env/bin/activate

# 2. Update credentials (if session expired)
aws configure set aws_session_token <NEW-TOKEN>

# 3. Work with cluster
kubectl get pods
```
