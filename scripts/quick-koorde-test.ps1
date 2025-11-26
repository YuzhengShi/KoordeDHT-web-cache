# Quick single-config Koorde test
# Usage: .\quick-koorde-test.ps1 -Nodes 8 -Degree 4

param(
    [int]$Nodes = 8,
    [int]$Degree = 4,
    [int]$Requests = 100,
    [int]$Rate = 50,
    [switch]$KeepRunning = $false
)

$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host "  Quick Koorde Test: $Nodes nodes, degree=$Degree" -ForegroundColor Cyan
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host ""

# Calculate theoretical performance
$m = [Math]::Ceiling([Math]::Log($Nodes) / [Math]::Log(2))
$logD = [Math]::Max(1, [Math]::Log($Degree) / [Math]::Log(2))
$koordeHops = [Math]::Ceiling($m / $logD)
Write-Host "Theoretical routing hops:" -ForegroundColor Yellow
Write-Host "  Chord:  ~$m hops"
Write-Host "  Koorde: ~$koordeHops hops"
Write-Host ""

# Stop existing nodes
Write-Host "[1/5] Stopping existing nodes..." -ForegroundColor Gray
Get-Process -Name "koorde-node" -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 2

# Generate config
Write-Host "[2/5] Generating cluster configuration..." -ForegroundColor Gray
& ./scripts/generate-cluster-configs.ps1 -Nodes $Nodes -Degree $Degree -OutputDir "config/test-cluster" | Out-Null

# Create logs dir
New-Item -ItemType Directory -Path "logs" -Force | Out-Null

# Start nodes
Write-Host "[3/5] Starting $Nodes nodes..." -ForegroundColor Gray

# Start node 0 first
Start-Process -FilePath ".\bin\koorde-node.exe" `
    -ArgumentList "-config", "config/test-cluster/node0.yaml" `
    -RedirectStandardOutput "logs/quick-node0.log" `
    -RedirectStandardError "logs/quick-node0.err" `
    -WindowStyle Hidden

Start-Sleep -Seconds 3

# Start remaining nodes
for ($i = 1; $i -lt $Nodes; $i++) {
    Start-Process -FilePath ".\bin\koorde-node.exe" `
        -ArgumentList "-config", "config/test-cluster/node$i.yaml" `
        -RedirectStandardOutput "logs/quick-node$i.log" `
        -RedirectStandardError "logs/quick-node$i.err" `
        -WindowStyle Hidden
    Start-Sleep -Milliseconds 300
}

# Wait for stabilization
Write-Host "[4/5] Waiting for cluster stabilization..." -ForegroundColor Gray
Start-Sleep -Seconds 15

# Check health
Write-Host ""
Write-Host "Node Status:" -ForegroundColor Cyan
$readyCount = 0
for ($i = 0; $i -lt $Nodes; $i++) {
    $port = 8080 + $i
    try {
        $health = Invoke-RestMethod "http://localhost:$port/health" -TimeoutSec 3
        $status = $health.status
        $dbCount = $health.de_bruijn_count
        if ($status -eq "READY") { 
            $readyCount++
            Write-Host "  Node $i port $port - $status - de Bruijn: $dbCount" -ForegroundColor Green
        } else {
            Write-Host "  Node $i port $port - $status - de Bruijn: $dbCount" -ForegroundColor Yellow
        }
    } catch {
        Write-Host "  Node $i port $port - UNREACHABLE" -ForegroundColor Red
    }
}

Write-Host ""
if ($readyCount -eq $Nodes) {
    Write-Host "Ready: $readyCount / $Nodes" -ForegroundColor Green
} else {
    Write-Host "Ready: $readyCount / $Nodes" -ForegroundColor Yellow
}
Write-Host ""

if ($readyCount -lt $Nodes) {
    Write-Host "WARNING: Not all nodes ready. Waiting 10 more seconds..." -ForegroundColor Yellow
    Start-Sleep -Seconds 10
}

# Run workload
Write-Host "[5/5] Running workload..." -ForegroundColor Gray
Write-Host ""

$targets = @()
for ($i = 0; $i -lt $Nodes; $i++) {
    $port = 8080 + $i
    $targets += "http://localhost:$port"
}
$targetsStr = $targets -join ','
& ./bin/cache-workload.exe -targets $targetsStr -requests $Requests -rate $Rate -urls 200 -output results-quick.csv

# Get metrics
Write-Host ""
Write-Host "=== Routing Statistics ===" -ForegroundColor Yellow
Write-Host ""

$totalDB = 0
$totalSucc = 0
$totalEntries = 0

for ($i = 0; $i -lt $Nodes; $i++) {
    $port = 8080 + $i
    try {
        $metrics = Invoke-RestMethod "http://localhost:$port/metrics" -TimeoutSec 3
        $db = $metrics.routing.stats.de_bruijn_success
        $succ = $metrics.routing.stats.successor_fallbacks
        $entries = $metrics.routing.debruijn_count
        $totalDB += $db
        $totalSucc += $succ
        $totalEntries += $entries
        
        $total = $db + $succ
        if ($total -gt 0) {
            $ratio = [Math]::Round($db / $total * 100, 1)
        } else {
            $ratio = 0
        }
        Write-Host "  Node $i : de_bruijn=$db, successor=$succ, ratio=$ratio%, entries=$entries"
    } catch {
        Write-Host "  Node $i : ERROR getting metrics" -ForegroundColor Red
    }
}

Write-Host ""
Write-Host "-----------------------------------------" -ForegroundColor Gray
$totalAll = $totalDB + $totalSucc
if ($totalAll -gt 0) {
    $totalRatio = [Math]::Round($totalDB / $totalAll * 100, 1)
} else {
    $totalRatio = 0
}
$avgEntries = [Math]::Round($totalEntries / $Nodes, 1)
Write-Host "  TOTAL: de_bruijn=$totalDB, successor=$totalSucc" -ForegroundColor Cyan
Write-Host "  De Bruijn Usage: $totalRatio%" -ForegroundColor Cyan
Write-Host "  Avg DB Entries:  $avgEntries - target: $Degree" -ForegroundColor Cyan
Write-Host ""

# Cleanup
if (-not $KeepRunning) {
    Write-Host "Stopping cluster..." -ForegroundColor Gray
    Get-Process -Name "koorde-node" -ErrorAction SilentlyContinue | Stop-Process -Force
    Write-Host "Done!" -ForegroundColor Green
} else {
    Write-Host "Cluster is still running. Use the following to stop:" -ForegroundColor Yellow
    Write-Host "  Get-Process -Name koorde-node | Stop-Process -Force" -ForegroundColor Gray
    Write-Host ""
    Write-Host "Useful endpoints:" -ForegroundColor Cyan
    for ($i = 0; $i -lt [Math]::Min($Nodes, 3); $i++) {
        $port = 8080 + $i
        Write-Host "  http://localhost:$port/health"
        Write-Host "  http://localhost:$port/metrics"
        Write-Host "  http://localhost:$port/debug"
    }
    if ($Nodes -gt 3) {
        $remaining = $Nodes - 3
        Write-Host "  ... $remaining more nodes"
    }
}
