param(
    [ValidateSet("koorde", "chord")]
    [string]$Protocol = "koorde",
    [int]$Nodes = 3,
    [int]$Degree = 2,
    [int]$BasePort = 4000,
    [int]$BaseHttpPort = 8080
)

$ComposeFile = "docker-compose.yml"
$NginxFile = "nginx.conf"

Write-Host "Generating configuration for $Nodes $Protocol nodes (Degree: $Degree)..." -ForegroundColor Cyan

# -----------------------------------------------------------------------------
# 1. Generate nginx.conf
# -----------------------------------------------------------------------------
$nginxContent = @"
upstream ${Protocol}_nodes {
"@

for ($i = 0; $i -lt $Nodes; $i++) {
    $port = $BaseHttpPort + $i
    $nginxContent += "`r`n    server ${Protocol}-node-" + $i + ":" + $port + ";"
}

$nginxContent += @"

}

server {
    listen 80;
    resolver 127.0.0.11 valid=10s;
    
    location / {
        proxy_pass http://${Protocol}_nodes;
        proxy_set_header Host `$host;
        proxy_set_header X-Real-IP `$remote_addr;
        proxy_set_header X-Forwarded-For `$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto `$scheme;
        
        # Timeouts
        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
    }
}
"@

Set-Content -Path $NginxFile -Value $nginxContent
Write-Host "Created $NginxFile" -ForegroundColor Green

# -----------------------------------------------------------------------------
# 2. Generate docker-compose.yml
# -----------------------------------------------------------------------------
$composeHeader = @"
version: '3.8'

services:
  localstack:
    image: localstack/localstack:latest
    ports:
      - "4566:4566"            # LocalStack Gateway
      - "4510-4559:4510-4559"  # External services port range
    environment:
      - SERVICES=route53
      - DEBUG=`${DEBUG:-0}
      - DOCKER_HOST=unix:///var/run/docker.sock
    volumes:
      - "`${LOCALSTACK_VOLUME_DIR:-./volume}:/var/lib/localstack"
      - "/var/run/docker.sock:/var/run/docker.sock"

  nginx-lb:
    image: nginx:alpine
    ports:
      - "9000:80"  # Load balancer on port 9000
    volumes:
      - ./nginx.conf:/etc/nginx/conf.d/default.conf:ro
    depends_on:
"@

$composeContent = $composeHeader

for ($i = 0; $i -lt $Nodes; $i++) {
    $composeContent += "`r`n      - ${Protocol}-node-$i"
}

$composeContent += "`r`n"

$serviceTemplate = @"

  ${Protocol}-node-__ID__:
    build:
      context: ../../
      dockerfile: docker/node.Dockerfile
    environment:
      - DHT_PROTOCOL=${Protocol}
      - NODE_ID=__HEX_ID__
      - NODE_HOST=${Protocol}-node-__ID__
      - NODE_PORT=__NODE_PORT__
      - NODE_BIND=0.0.0.0
      - CACHE_HTTP_PORT=__HTTP_PORT__
      - BOOTSTRAP_MODE=route53
      - DEBRUIJN_DEGREE=__DEGREE__
      - ROUTE53_ZONE_ID=`${ROUTE53_ZONE_ID:-Z00000000000000000000}
      - ROUTE53_SUFFIX=dht.local
      - ROUTE53_REGION=us-east-1
      - ROUTE53_ENDPOINT=http://localstack:4566
      - AWS_ACCESS_KEY_ID=test
      - AWS_SECRET_ACCESS_KEY=test
      - AWS_REGION=us-east-1
    ports:
      - "__NODE_PORT__:__NODE_PORT__"
      - "__HTTP_PORT__:__HTTP_PORT__"
    depends_on:
      - localstack
"@

for ($i = 0; $i -lt $Nodes; $i++) {
    $nodePort = $BasePort + $i
    $httpPort = $BaseHttpPort + $i
    
    # Generate 16-character hex ID (64-bit)
    # Format: 0000000000000000, 0000000000000001, etc.
    $hexId = "{0:x16}" -f $i
    
    $block = $serviceTemplate.Replace("__ID__", "$i")
    $block = $block.Replace("__HEX_ID__", $hexId)
    $block = $block.Replace("__NODE_PORT__", "$nodePort")
    $block = $block.Replace("__HTTP_PORT__", "$httpPort")
    $block = $block.Replace("__DEGREE__", "$Degree")
    
    $composeContent += $block
}

Set-Content -Path $ComposeFile -Value $composeContent
Write-Host "Created $ComposeFile" -ForegroundColor Green
Write-Host "Ready to deploy $Nodes $Protocol nodes!" -ForegroundColor Green
