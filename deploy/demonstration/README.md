# Multi-Instance AWS Deployment with Route53

This deployment represents the **production-ready mode** for the KoordeDHT-Web-Cache system, designed to replicate realistic production scenarios.

In this setup, **each EC2 instance** hosts **multiple Koorde containers** that automatically register with **AWS Route53**, enabling clients to interact with the DHT and web cache using only a DNS address.

---

## Architecture

### Per EC2 Instance

Each **EC2 instance** runs:
- **Local cluster** of N Koorde containers (each with DHT + web cache)
- **Docker and Docker Compose** (installed automatically)
- **Automatic DNS registration** to Route53 via `ROUTE53_ZONE_ID` and `ROUTE53_SUFFIX`

### Network Configuration

- Containers publish ports `BASEPORT+N` (one per node)
  - gRPC: `4000, 4001, 4002, ...`
  - HTTP cache: `8080, 8081, 8082, ...`
- All EC2 instances share the same **VPC** and **Route53 Hosted Zone**
- Creates a distributed network accessible from external clients

### Deployment Topology

```
┌─────────────────────────────────────────┐
│             Route53 DNS                 │
│  _koorde._tcp.koorde-dht.local          │
│    → node1.ec2:4000                     │
│    → node2.ec2:4001                     │
│    → node3.ec2:4000                     │
└─────────────────────────────────────────┘
           │         │         │
    ┌──────┘         │         └──────┐
    ↓                ↓                ↓
┌─────────┐    ┌─────────┐    ┌─────────┐
│  EC2 #1 │    │  EC2 #2 │    │  EC2 #3 │
│         │    │         │    │         │
│ Node 1  │    │ Node 1  │    │ Node 1  │
│ Node 2  │    │ Node 2  │    │ Node 2  │
│ Node 3  │    │ Node 3  │    │ Node 3  │
│ Node 4  │    │ Node 4  │    │ Node 4  │
│ Node 5  │    │ Node 5  │    │ Node 5  │
└─────────┘    └─────────┘    └─────────┘
```

---

## Prerequisites

### AWS Resources

1. **S3 Bucket** for scripts and configuration
2. **VPC** with at least one subnet
3. **Private Route53 Hosted Zone** associated with VPC
4. **Routing table** allowing communication between EC2 instances
5. **Internet Gateway** attached to VPC (for downloading Docker)
6. **IAM role** with Route53 permissions, attached to EC2 instances
7. **EC2 Key Pair** for SSH access

### Setup Checklist

```bash
# Upload scripts to S3
aws s3 sync scripts/ s3://koorde-bucket/demonstration/

# Verify VPC configuration
aws ec2 describe-vpcs --vpc-ids vpc-0123456789

# Check Route53 hosted zone
aws route53 list-hosted-zones

# Verify IAM role has Route53 permissions
aws iam get-role --role-name KoordeDHTRole
```

---

## Deployment

### Step 1: Generate docker-compose Template

The `gen_compose.sh` script generates `docker-compose.generated.yml` by:
- Replicating the node service N times (one per node)
- Assigning unique ports to each node
- Configuring Route53 registration

```bash
cd scripts

./gen_compose.sh \
  --nodes 5 \
  --base-port 4000 \
  --mode private \
  --zone-id Z1234567890ABC \
  --suffix dht.local \
  --region us-east-1
```

**Output**: `docker-compose.generated.yml` with 5 nodes on ports 4000-4004 (gRPC) and 8080-8084 (HTTP)

### Step 2: Deploy to AWS

```bash
./deploy_koorde.sh \
  --instances 3 \
  --nodes 5 \
  --base-port 4000 \
  --mode private \
  --zone-id Z1234567890ABC \
  --region us-east-1 \
  --suffix koorde-dht.local \
  --s3-bucket koorde-bucket \
  --s3-prefix demonstration \
  --key-name MyKeyPair \
  --instance-type t3.micro \
  --vpc-id vpc-0123456789abcdef \
  --subnet-id subnet-0123456789abcdef
```

**This creates**:
- 3 EC2 instances
- 5 Koorde nodes per instance = 15 total nodes
- Automatic Route53 SRV records
- CloudFormation stack named `koorde-dht-demo-<timestamp>`

### Step 3: Wait for Initialization

```bash
# CloudFormation takes 3-5 minutes to complete
aws cloudformation wait stack-create-complete \
  --stack-name koorde-dht-demo-<timestamp>

# Wait additional 2 minutes for DHT stabilization
sleep 120
```

---

## Accessing the Network

### Using the Interactive Client

```bash
# Get node address from Route53
aws route53 list-resource-record-sets \
  --hosted-zone-id Z1234567890ABC \
  | jq '.ResourceRecordSets[] | select(.Type == "SRV")'

# Connect to any node
docker run -it --rm \
  flaviosimonelli/koorde-client:latest \
  --addr <NODE_IP>:4000
```

### Client Commands

```
koorde[node:4000]> put mykey myvalue
Put succeeded (key=mykey, value=myvalue) | latency=45ms

koorde[node:4000]> get mykey
Get succeeded (key=mykey, value=myvalue) | latency=23ms

koorde[node:4000]> lookup 0x1a2b3c4d
Lookup result: successor=0x1a2b... (10.0.5.12:4000) | latency=67ms

koorde[node:4000]> getrt
Routing table:
  Self: 0x0139a675... (10.0.1.45:4000)
  Predecessor: 0x00ebb345... (10.0.5.89:4002)
  Successors: [...]
  DeBruijn List: [...]

koorde[node:4000]> exit
```

### Using the Web Cache API

```bash
# Cache a URL
curl "http://<NODE_IP>:8080/cache?url=https://example.com/page.html"

# Check metrics
curl "http://<NODE_IP>:8080/metrics" | jq

# Health check
curl "http://<NODE_IP>:8080/health"
```

---

## Orchestration Script (init.sh)

Each EC2 instance runs `init.sh` automatically via CloudFormation user data:

1. Downloads scripts from S3
2. Installs Docker and Docker Compose
3. Generates custom `docker-compose.generated.yml`
4. Starts Koorde containers
5. Containers register with Route53
6. Logs saved to `/var/log/init.log`

### Environment Variables

Before running `init.sh`, set:

```bash
export NODES=5
export BASE_PORT=4000
export MODE=private
export ROUTE53_ZONE_ID=Z1234567890ABC
export ROUTE53_SUFFIX=koorde-dht.local
export ROUTE53_REGION=us-east-1
export S3_BUCKET=koorde-bucket
export S3_PREFIX=demonstration
```

---

## Monitoring and Debugging

### SSH into EC2 Instance

```bash
ssh -i ~/.ssh/MyKeyPair.pem ec2-user@<EC2_PUBLIC_IP>
```

### Check Container Status

```bash
docker ps
docker-compose ps
docker-compose logs -f
```

### Verify Route53 Registration

```bash
# From your local machine
aws route53 list-resource-record-sets \
  --hosted-zone-id Z1234567890ABC \
  --query "ResourceRecordSets[?Type=='SRV']"
```

### Test Connectivity

```bash
# From any EC2 instance
curl http://localhost:8080/health
curl http://localhost:4000/debug  # If debug endpoint exists

# Test inter-node communication
docker exec koorde-node-1 /usr/local/bin/koorde-client --addr koorde-node-2:4000 getrt
```

---

## Teardown

### Delete CloudFormation Stack

```bash
./destroy_koorde.sh
```

This command:
1. Deletes all EC2 instances
2. Removes Route53 SRV records
3. Cleans up associated resources
4. Deletes CloudFormation stack

### Manual Cleanup

If needed:

```bash
# Delete specific stack
aws cloudformation delete-stack --stack-name koorde-dht-demo-<timestamp>

# Remove Route53 records manually
aws route53 change-resource-record-sets \
  --hosted-zone-id Z1234567890ABC \
  --change-batch file://delete-records.json
```

---

## Cost Estimation

For AWS deployment:

| Resource | Quantity | Hourly Cost (approx) |
|----------|----------|---------------------|
| t3.micro EC2 | 3 instances | $0.0104 × 3 = $0.031/hr |
| Route53 queries | Minimal | ~$0.01/hr |
| Data transfer | Low | ~$0.02/hr |
| **Total** | | **~$0.06/hr** |

**For a 1-hour demo**: ~$0.06
**For 24-hour testing**: ~$1.50

---

## Production Considerations

### Scaling

```bash
# Scale to 10 instances with 10 nodes each = 100 total nodes
./deploy_koorde.sh --instances 10 --nodes 10

# Increase instance size for production
--instance-type t3.medium
```

### Security

1. **Use private VPC** (already configured)
2. **Restrict security groups**:
   - Only allow gRPC from within VPC
   - Expose HTTP cache via load balancer
3. **Enable CloudWatch logs**
4. **Use IAM instance profiles** (not access keys)

### Monitoring

1. **CloudWatch Metrics**: CPU, memory, network
2. **Route53 Health Checks**: Monitor node availability
3. **Application Logs**: Stream to CloudWatch Logs
4. **Alerts**: Set up SNS notifications for failures

---

## Example Outputs

See `results/` directory for example client outputs showing:
- Routing table snapshots
- Lookup operations across nodes
- Inter-node communication
- Route53 DNS resolution

---

## Notes

- Each EC2 instance requires public IP for initial setup (pulls Docker images)
- Private mode uses private IPs for inter-node communication
- Route53 TTL of 30 seconds balances freshness and query costs
- IAM role must have `route53:ChangeResourceRecordSets` permission
- Container names follow pattern: `koorde-node-<instance>-<node>`

---

## Related Deployments

- [Local Testing with Tracing](../tracing/README.md) - Quick development
- [Automated Testing with Churn](../test/README.md) - Performance benchmarking
