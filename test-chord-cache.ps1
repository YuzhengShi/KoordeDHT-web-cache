# Test Chord Cache Operations
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Testing Chord Cache Operations" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

# Build if needed
if (-not (Test-Path "bin/node.exe")) {
    Write-Host "Building node binary..." -ForegroundColor Yellow
    New-Item -ItemType Directory -Force -Path "bin" | Out-Null
    go build -o bin/node.exe ./cmd/node
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Build failed!" -ForegroundColor Red
        exit 1
    }
}

# Create test configs
New-Item -ItemType Directory -Force -Path "config/chord-test" | Out-Null
Remove-Item -Path "config/chord-test/*.yaml" -ErrorAction SilentlyContinue

# Node 1 (Bootstrap)
@"
logger:
  active: true
  level: info
  encoding: console
  mode: stdout

dht:
  idBits: 66
  protocol: chord
  mode: private
  bootstrap:
    mode: static
    peers: []
  deBruijn:
    degree: 2
    fixInterval: 5s
  faultTolerance:
    successorListSize: 8
    stabilizationInterval: 2s
    failureTimeout: 1s
  storage:
    fixInterval: 20s

node:
  id: ""
  bind: "0.0.0.0"
  host: "localhost"
  port: 4000

cache:
  enabled: true
  httpPort: 8080
  capacityMB: 512
  defaultTTL: 3600
  hotspotThreshold: 10.0
  hotspotDecayRate: 0.65

telemetry:
  tracing:
    enabled: false
"@ | Out-File -FilePath "config/chord-test/node1.yaml" -Encoding utf8

# Node 2 (Join)
@"
logger:
  active: true
  level: info
  encoding: console
  mode: stdout

dht:
  idBits: 66
  protocol: chord
  mode: private
  bootstrap:
    mode: static
    peers: ["localhost:4000"]
  deBruijn:
    degree: 2
    fixInterval: 5s
  faultTolerance:
    successorListSize: 8
    stabilizationInterval: 2s
    failureTimeout: 1s
  storage:
    fixInterval: 20s

node:
  id: ""
  bind: "0.0.0.0"
  host: "localhost"
  port: 4001

cache:
  enabled: true
  httpPort: 8081
  capacityMB: 512
  defaultTTL: 3600
  hotspotThreshold: 10.0
  hotspotDecayRate: 0.65

telemetry:
  tracing:
    enabled: false
"@ | Out-File -FilePath "config/chord-test/node2.yaml" -Encoding utf8

# Node 3 (Join)
@"
logger:
  active: true
  level: info
  encoding: console
  mode: stdout

dht:
  idBits: 66
  protocol: chord
  mode: private
  bootstrap:
    mode: static
    peers: ["localhost:4000"]
  deBruijn:
    degree: 2
    fixInterval: 5s
  faultTolerance:
    successorListSize: 8
    stabilizationInterval: 2s
    failureTimeout: 1s
  storage:
    fixInterval: 20s

node:
  id: ""
  bind: "0.0.0.0"
  host: "localhost"
  port: 4002

cache:
  enabled: true
  httpPort: 8082
  capacityMB: 512
  defaultTTL: 3600
  hotspotThreshold: 10.0
  hotspotDecayRate: 0.65

telemetry:
  tracing:
    enabled: false
"@ | Out-File -FilePath "config/chord-test/node3.yaml" -Encoding utf8

Write-Host "Starting Chord cluster..." -ForegroundColor Green
Write-Host ""

# Create logs directory
New-Item -ItemType Directory -Force -Path "logs" | Out-Null

# Store current directory for jobs
$scriptDir = Get-Location

# Start nodes in background using jobs
Write-Host "Starting Node 1 (bootstrap)..." -ForegroundColor Yellow
$node1Job = Start-Job -ScriptBlock {
    param($dir, $config)
    Set-Location $dir
    & "bin/node.exe" -config $config *> "logs/chord-node1.log" 2>&1
} -ArgumentList $scriptDir, "config/chord-test/node1.yaml"
Write-Host "Node 1 Job ID: $($node1Job.Id)" -ForegroundColor Gray

Start-Sleep -Seconds 3

Write-Host "Starting Node 2..." -ForegroundColor Yellow
$node2Job = Start-Job -ScriptBlock {
    param($dir, $config)
    Set-Location $dir
    & "bin/node.exe" -config $config *> "logs/chord-node2.log" 2>&1
} -ArgumentList $scriptDir, "config/chord-test/node2.yaml"
Write-Host "Node 2 Job ID: $($node2Job.Id)" -ForegroundColor Gray

Start-Sleep -Seconds 3

Write-Host "Starting Node 3..." -ForegroundColor Yellow
$node3Job = Start-Job -ScriptBlock {
    param($dir, $config)
    Set-Location $dir
    & "bin/node.exe" -config $config *> "logs/chord-node3.log" 2>&1
} -ArgumentList $scriptDir, "config/chord-test/node3.yaml"
Write-Host "Node 3 Job ID: $($node3Job.Id)" -ForegroundColor Gray

Write-Host ""
Write-Host "Waiting 15 seconds for cluster to stabilize and finger table to populate..." -ForegroundColor Yellow
Start-Sleep -Seconds 15

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Testing Cache Operations" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

# Test 1: Health check
Write-Host "Test 1: Health Check" -ForegroundColor Green
Write-Host "-------------------" -ForegroundColor Gray
foreach ($port in @(8080, 8081, 8082)) {
    Write-Host -NoNewline "Node on port $port`: "
    try {
        $response = Invoke-WebRequest -Uri "http://localhost:$port/health" -TimeoutSec 5 -UseBasicParsing
        if ($response.Content -match '"healthy":\s*true') {
            Write-Host "✓ Healthy" -ForegroundColor Green
        } else {
            Write-Host "✗ Unhealthy" -ForegroundColor Red
        }
    } catch {
        Write-Host "✗ Error: $_" -ForegroundColor Red
    }
}
Write-Host ""

# Test 2: Debug endpoint
Write-Host "Test 2: Debug Endpoint (Check Finger Table)" -ForegroundColor Green
Write-Host "---------------------------------------------" -ForegroundColor Gray
foreach ($port in @(8080, 8081, 8082)) {
    Write-Host "Node on port $port`:"
    try {
        $response = Invoke-WebRequest -Uri "http://localhost:$port/debug" -TimeoutSec 5 -UseBasicParsing
        $json = $response.Content | ConvertFrom-Json
        Write-Host "  Successors: $($json.routing.successor_count)" -ForegroundColor Cyan
        Write-Host "  DeBruijn: $($json.routing.debruijn_count) (should be 0 for Chord)" -ForegroundColor Cyan
        Write-Host "  Has Predecessor: $($json.routing.has_predecessor)" -ForegroundColor Cyan
    } catch {
        Write-Host "  ✗ Error: $_" -ForegroundColor Red
    }
}
Write-Host ""

# Test 3: Cache operations
Write-Host "Test 3: Cache Operations" -ForegroundColor Green
Write-Host "------------------------" -ForegroundColor Gray
$testUrl = "https://httpbin.org/json"

Write-Host "Requesting $testUrl from Node 1 (port 8080)..." -ForegroundColor Yellow
try {
    $response1 = Invoke-WebRequest -Uri "http://localhost:8080/cache?url=$testUrl" -TimeoutSec 30 -UseBasicParsing
    $cacheStatus1 = $response1.Headers["X-Cache"]
    Write-Host "  HTTP Code: $($response1.StatusCode)" -ForegroundColor Cyan
    Write-Host "  Cache Status: $cacheStatus1" -ForegroundColor Cyan
} catch {
    Write-Host "  ✗ Error: $_" -ForegroundColor Red
}
Write-Host ""

Write-Host "Requesting same URL from Node 2 (port 8081)..." -ForegroundColor Yellow
try {
    $response2 = Invoke-WebRequest -Uri "http://localhost:8081/cache?url=$testUrl" -TimeoutSec 30 -UseBasicParsing
    $cacheStatus2 = $response2.Headers["X-Cache"]
    Write-Host "  HTTP Code: $($response2.StatusCode)" -ForegroundColor Cyan
    Write-Host "  Cache Status: $cacheStatus2" -ForegroundColor Cyan
} catch {
    Write-Host "  ✗ Error: $_" -ForegroundColor Red
}
Write-Host ""

Write-Host "Requesting same URL again from Node 1 (should be cached)..." -ForegroundColor Yellow
try {
    $response3 = Invoke-WebRequest -Uri "http://localhost:8080/cache?url=$testUrl" -TimeoutSec 30 -UseBasicParsing
    $cacheStatus3 = $response3.Headers["X-Cache"]
    Write-Host "  HTTP Code: $($response3.StatusCode)" -ForegroundColor Cyan
    Write-Host "  Cache Status: $cacheStatus3" -ForegroundColor Cyan
    if ($cacheStatus3 -eq "HIT-LOCAL") {
        Write-Host "  ✓ Cache hit confirmed!" -ForegroundColor Green
    }
} catch {
    Write-Host "  ✗ Error: $_" -ForegroundColor Red
}
Write-Host ""

# Test 4: Metrics
Write-Host "Test 4: Cache Metrics" -ForegroundColor Green
Write-Host "--------------------" -ForegroundColor Gray
foreach ($port in @(8080, 8081, 8082)) {
    Write-Host "Node on port $port`:"
    try {
        $response = Invoke-WebRequest -Uri "http://localhost:$port/metrics" -TimeoutSec 5 -UseBasicParsing
        $json = $response.Content | ConvertFrom-Json
        Write-Host "  Hits: $($json.cache.hits)" -ForegroundColor Cyan
        Write-Host "  Misses: $($json.cache.misses)" -ForegroundColor Cyan
        Write-Host "  Hit Rate: $([math]::Round($json.cache.hit_rate, 3))" -ForegroundColor Cyan
        Write-Host "  Entries: $($json.cache.entry_count)" -ForegroundColor Cyan
    } catch {
        Write-Host "  ✗ Error: $_" -ForegroundColor Red
    }
}
Write-Host ""

# Test 5: Multiple URLs
Write-Host "Test 5: Multiple URLs (Distribution Test)" -ForegroundColor Green
Write-Host "--------------------------------------" -ForegroundColor Gray
$urls = @(
    "https://httpbin.org/json",
    "https://httpbin.org/uuid",
    "https://httpbin.org/base64/SFRUUEJJTiBpcyBhd2Vzb21l"
)

foreach ($url in $urls) {
    Write-Host "Requesting $url from Node 1..." -ForegroundColor Yellow
    try {
        $response = Invoke-WebRequest -Uri "http://localhost:8080/cache?url=$url" -TimeoutSec 30 -UseBasicParsing
        $nodeId = $response.Headers["X-Node-ID"]
        $cacheStatus = $response.Headers["X-Cache"]
        Write-Host "  Responsible Node: $nodeId" -ForegroundColor Cyan
        Write-Host "  Cache Status: $cacheStatus" -ForegroundColor Cyan
    } catch {
        Write-Host "  ✗ Error: $_" -ForegroundColor Red
    }
}
Write-Host ""

Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Test Summary" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "All tests completed. Check logs in logs/chord-node*.log for details." -ForegroundColor Yellow
Write-Host ""
Write-Host "To stop the cluster, run:" -ForegroundColor Yellow
Write-Host "  Stop-Job -Job $($node1Job.Id), $($node2Job.Id), $($node3Job.Id)" -ForegroundColor Gray
Write-Host ""
Write-Host "Or use: Get-Job | Stop-Job; Get-Job | Remove-Job" -ForegroundColor Gray
Write-Host ""

# Keep processes running - user can stop manually
Write-Host "Cluster is still running. Press Ctrl+C to stop all nodes." -ForegroundColor Yellow
Write-Host ""

# Wait for user interrupt
try {
    while ($true) {
        Start-Sleep -Seconds 1
        # Check if jobs are still running
        $job1 = Get-Job -Id $node1Job.Id -ErrorAction SilentlyContinue
        $job2 = Get-Job -Id $node2Job.Id -ErrorAction SilentlyContinue
        $job3 = Get-Job -Id $node3Job.Id -ErrorAction SilentlyContinue
        
        if (-not $job1 -or $job1.State -eq "Completed" -or $job1.State -eq "Failed") {
            Write-Host "Node 1 stopped." -ForegroundColor Red
            break
        }
        if (-not $job2 -or $job2.State -eq "Completed" -or $job2.State -eq "Failed") {
            Write-Host "Node 2 stopped." -ForegroundColor Red
            break
        }
        if (-not $job3 -or $job3.State -eq "Completed" -or $job3.State -eq "Failed") {
            Write-Host "Node 3 stopped." -ForegroundColor Red
            break
        }
    }
} finally {
    Write-Host "Stopping all nodes..." -ForegroundColor Yellow
    Stop-Job -Job $node1Job, $node2Job, $node3Job -ErrorAction SilentlyContinue
    Remove-Job -Job $node1Job, $node2Job, $node3Job -ErrorAction SilentlyContinue
    Write-Host "Done." -ForegroundColor Green
}

