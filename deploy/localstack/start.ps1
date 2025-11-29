$ErrorActionPreference = "Stop"

Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Starting LocalStack Deployment" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan

# Check for awslocal or aws
if (Get-Command awslocal -ErrorAction SilentlyContinue) {
    $AWS_CMD = "awslocal"
} else {
    Write-Host "awslocal not found, using 'aws --endpoint-url=http://localhost:4566'" -ForegroundColor Yellow
    $AWS_CMD = "aws --endpoint-url=http://localhost:4566"
}

Write-Host "[1/4] Starting LocalStack..." -ForegroundColor Green
docker-compose up -d localstack

Write-Host "Waiting for LocalStack to be ready..." -ForegroundColor Gray
$retryCount = 0
while ($retryCount -lt 30) {
    try {
        Invoke-Expression "$AWS_CMD route53 list-hosted-zones" | Out-Null
        break
    } catch {
        Write-Host -NoNewline "."
        Start-Sleep -Seconds 2
        $retryCount++
    }
}
Write-Host " Ready!" -ForegroundColor Green

Write-Host "[2/4] Creating Route53 Hosted Zone..." -ForegroundColor Green
# Create hosted zone if it doesn't exist
$zones = Invoke-Expression "$AWS_CMD route53 list-hosted-zones" | ConvertFrom-Json
if (-not ($zones.HostedZones | Where-Object { $_.Name -eq "dht.local." })) {
    $callerRef = (Get-Date).Ticks
    Invoke-Expression "$AWS_CMD route53 create-hosted-zone --name dht.local --caller-reference $callerRef" | Out-Null
    Write-Host "Created hosted zone: dht.local"
} else {
    Write-Host "Hosted zone dht.local already exists"
}

# Get Zone ID
$zones = Invoke-Expression "$AWS_CMD route53 list-hosted-zones" | ConvertFrom-Json
$ZONE_ID = ($zones.HostedZones | Where-Object { $_.Name -eq "dht.local." }).Id.Split("/")[-1]
Write-Host "Zone ID: $ZONE_ID" -ForegroundColor Cyan

Write-Host "[3/4] Starting Koorde Nodes with Zone ID: $ZONE_ID..." -ForegroundColor Green
$env:ROUTE53_ZONE_ID = $ZONE_ID
docker-compose up -d --build

Write-Host "[4/4] Deployment Complete!" -ForegroundColor Green
Write-Host ""
Write-Host "Load Balancer:" -ForegroundColor Cyan
Write-Host "  http://localhost:9000 (nginx - distributes across all nodes)"
Write-Host ""
Write-Host "Individual Nodes:" -ForegroundColor Cyan
Write-Host "  Node 0: HTTP 8080, gRPC 4000"
Write-Host "  Node 1: HTTP 8081, gRPC 4001"
Write-Host "  Node 2: HTTP 8082, gRPC 4002"
Write-Host ""
Write-Host "Verify with:"
Write-Host "  curl http://localhost:9000/health  # Via load balancer"
Write-Host "  curl http://localhost:8080/health  # Direct to node 0"
Write-Host ""
