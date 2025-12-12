<#
.SYNOPSIS
    Tests Chord vs Koorde performance during node membership changes (add/remove).
    Measures: stabilization time, routing success rate, latency during churn.

.PARAMETER Protocol
    DHT protocol to test: "chord" or "koorde"

.PARAMETER InitialNodes
    Number of nodes to start with (default: 16)

.PARAMETER NodesToAdd
    Number of nodes to add during test (default: 8)

.PARAMETER NodesToRemove
    Number of nodes to remove during test (default: 4)

.PARAMETER Degree
    De Bruijn degree for Koorde (default: 4)

.EXAMPLE
    .\test-membership-churn.ps1 -Protocol chord -InitialNodes 16
    .\test-membership-churn.ps1 -Protocol koorde -InitialNodes 16 -Degree 4
#>

param(
    [Parameter(Mandatory=$true)]
    [ValidateSet("chord", "koorde")]
    [string]$Protocol,
    
    [int]$InitialNodes = 16,
    [int]$NodesToAdd = 8,
    [int]$NodesToRemove = 4,
    [int]$Degree = 4,
    [int]$RequestsPerTest = 500,
    [int]$RequestRate = 50
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$LocalstackDir = Join-Path (Split-Path -Parent $ScriptDir) "deploy\localstack"
$BinDir = Join-Path (Split-Path -Parent $ScriptDir) "bin"
$ResultsFile = Join-Path (Split-Path -Parent $ScriptDir) "churn-results-$Protocol.csv"

# Results storage
$Results = @()

function Write-Status {
    param([string]$Message, [string]$Color = "Cyan")
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $Message" -ForegroundColor $Color
}

function Run-Benchmark {
    param(
        [string]$Phase,
        [int]$Requests = $RequestsPerTest,
        [int]$Rate = $RequestRate
    )
    
    Write-Status "Running benchmark: $Phase ($Requests requests @ $Rate/s)"
    
    $startTime = Get-Date
    
    # Run workload and capture output
    $output = & "$BinDir\cache-workload.exe" `
        -targets "http://localhost:9000" `
        -requests $Requests `
        -rate $Rate `
        -urls 100 `
        -zipf 1.2 2>&1 | Out-String
    
    $endTime = Get-Date
    $duration = ($endTime - $startTime).TotalSeconds
    
    # Parse results from output
    $p50 = 0
    $p99 = 0
    $successRate = 0
    $hitRate = 0
    
    if ($output -match "p50[:\s]+(\d+\.?\d*)") { $p50 = [double]$Matches[1] }
    if ($output -match "p99[:\s]+(\d+\.?\d*)") { $p99 = [double]$Matches[1] }
    if ($output -match "success[:\s]+(\d+\.?\d*)%?") { $successRate = [double]$Matches[1] }
    if ($output -match "hit[:\s]+(\d+\.?\d*)%?") { $hitRate = [double]$Matches[1] }
    
    # Also try to get error count
    $errors = 0
    if ($output -match "errors?[:\s]+(\d+)") { $errors = [int]$Matches[1] }
    
    $result = [PSCustomObject]@{
        Protocol = $Protocol
        Phase = $Phase
        Nodes = (docker ps --filter "name=koorde-node" -q | Measure-Object).Count
        Requests = $Requests
        P50_ms = $p50
        P99_ms = $p99
        SuccessRate = $successRate
        HitRate = $hitRate
        Errors = $errors
        Duration_s = [math]::Round($duration, 2)
        Timestamp = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    }
    
    Write-Status "  P50: ${p50}ms, P99: ${p99}ms, Success: ${successRate}%, Errors: $errors" -Color $(if ($errors -gt 0) { "Yellow" } else { "Green" })
    
    return $result
}

function Wait-ForStabilization {
    param([int]$Seconds = 30)
    Write-Status "Waiting ${Seconds}s for ring stabilization..."
    Start-Sleep -Seconds $Seconds
}

function Add-Nodes {
    param([int]$Count)
    
    Write-Status "Adding $Count nodes to cluster..." -Color Yellow
    
    $currentNodes = (docker ps --filter "name=koorde-node" --format "{{.Names}}" | 
        ForEach-Object { if ($_ -match "koorde-node-(\d+)") { [int]$Matches[1] } } | 
        Measure-Object -Maximum).Maximum
    
    $networkName = "localstack_koorde-net"
    
    for ($i = 1; $i -le $Count; $i++) {
        $newNodeId = $currentNodes + $i
        $nodeName = "koorde-node-$newNodeId"
        $port = 8080 + $newNodeId
        
        Write-Status "  Starting $nodeName..."
        
        # Get bootstrap nodes (use first 2 existing nodes)
        $bootstrapNodes = "koorde-node-0:8080,koorde-node-1:8080"
        
        $envVars = @(
            "-e", "NODE_HOST=$nodeName",
            "-e", "NODE_PORT=8080",
            "-e", "HTTP_PORT=8081",
            "-e", "DHT_PROTOCOL=$Protocol",
            "-e", "BOOTSTRAP_NODES=$bootstrapNodes",
            "-e", "CACHE_CAPACITY_MB=64",
            "-e", "CACHE_TTL_SECONDS=300",
            "-e", "CACHE_ENABLED=false"
        )
        
        if ($Protocol -eq "koorde") {
            $envVars += @("-e", "DEBRUIJN_DEGREE=$Degree")
        }
        
        docker run -d `
            --name $nodeName `
            --network $networkName `
            @envVars `
            koorde-node:latest 2>&1 | Out-Null
        
        if ($LASTEXITCODE -ne 0) {
            Write-Status "  Failed to start $nodeName" -Color Red
        }
    }
    
    Write-Status "Added $Count nodes (now at $($currentNodes + $Count + 1) total)" -Color Green
}

function Remove-Nodes {
    param([int]$Count)
    
    Write-Status "Removing $Count nodes from cluster..." -Color Yellow
    
    # Get list of node numbers (excluding node 0 and 1 which are bootstrap)
    $nodeNumbers = docker ps --filter "name=koorde-node" --format "{{.Names}}" | 
        ForEach-Object { if ($_ -match "koorde-node-(\d+)") { [int]$Matches[1] } } |
        Where-Object { $_ -gt 1 } |
        Sort-Object -Descending |
        Select-Object -First $Count
    
    foreach ($nodeNum in $nodeNumbers) {
        $nodeName = "koorde-node-$nodeNum"
        Write-Status "  Stopping $nodeName..."
        docker stop $nodeName 2>&1 | Out-Null
        docker rm $nodeName 2>&1 | Out-Null
    }
    
    $remaining = (docker ps --filter "name=koorde-node" -q | Measure-Object).Count
    Write-Status "Removed $Count nodes ($remaining remaining)" -Color Green
}

function Measure-StabilizationTime {
    param([string]$Phase)
    
    Write-Status "Measuring stabilization time for $Phase..."
    
    $startTime = Get-Date
    $maxAttempts = 60
    $attempt = 0
    $consecutiveSuccess = 0
    $requiredSuccess = 3
    
    while ($attempt -lt $maxAttempts -and $consecutiveSuccess -lt $requiredSuccess) {
        $attempt++
        
        # Quick probe - just 10 requests
        $output = & "$BinDir\cache-workload.exe" `
            -targets "http://localhost:9000" `
            -requests 10 `
            -rate 10 `
            -urls 10 `
            -zipf 1.0 2>&1 | Out-String
        
        $errors = 0
        if ($output -match "errors?[:\s]+(\d+)") { $errors = [int]$Matches[1] }
        
        if ($errors -eq 0) {
            $consecutiveSuccess++
        } else {
            $consecutiveSuccess = 0
        }
        
        Start-Sleep -Seconds 1
    }
    
    $stabilizationTime = ((Get-Date) - $startTime).TotalSeconds
    
    if ($consecutiveSuccess -ge $requiredSuccess) {
        Write-Status "  Stabilized in ${stabilizationTime}s" -Color Green
    } else {
        Write-Status "  Failed to stabilize after ${stabilizationTime}s" -Color Red
    }
    
    return $stabilizationTime
}

function Run-ConcurrentBenchmarkDuringChurn {
    param(
        [string]$ChurnType,  # "add" or "remove"
        [int]$NodeCount
    )
    
    Write-Status "Running benchmark DURING $ChurnType of $NodeCount nodes..." -Color Magenta
    
    # Start benchmark in background
    $benchmarkJob = Start-Job -ScriptBlock {
        param($BinDir, $Requests, $Rate)
        & "$BinDir\cache-workload.exe" `
            -targets "http://localhost:9000" `
            -requests $Requests `
            -rate $Rate `
            -urls 100 `
            -zipf 1.2 2>&1
    } -ArgumentList $BinDir, ($RequestsPerTest * 2), $RequestRate
    
    # Wait a moment for benchmark to start
    Start-Sleep -Seconds 2
    
    # Perform churn
    if ($ChurnType -eq "add") {
        Add-Nodes -Count $NodeCount
    } else {
        Remove-Nodes -Count $NodeCount
    }
    
    # Wait for benchmark to complete
    $output = Receive-Job -Job $benchmarkJob -Wait | Out-String
    Remove-Job -Job $benchmarkJob
    
    # Parse results
    $p50 = 0; $p99 = 0; $errors = 0
    if ($output -match "p50[:\s]+(\d+\.?\d*)") { $p50 = [double]$Matches[1] }
    if ($output -match "p99[:\s]+(\d+\.?\d*)") { $p99 = [double]$Matches[1] }
    if ($output -match "errors?[:\s]+(\d+)") { $errors = [int]$Matches[1] }
    
    $result = [PSCustomObject]@{
        Protocol = $Protocol
        Phase = "During-$ChurnType"
        Nodes = (docker ps --filter "name=koorde-node" -q | Measure-Object).Count
        Requests = $RequestsPerTest * 2
        P50_ms = $p50
        P99_ms = $p99
        SuccessRate = 0
        HitRate = 0
        Errors = $errors
        Duration_s = 0
        Timestamp = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    }
    
    Write-Status "  During churn - P50: ${p50}ms, P99: ${p99}ms, Errors: $errors" -Color $(if ($errors -gt 0) { "Yellow" } else { "Green" })
    
    return $result
}

# ============ MAIN TEST FLOW ============

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  MEMBERSHIP CHURN TEST: $($Protocol.ToUpper())" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Initial Nodes: $InitialNodes"
Write-Host "  Nodes to Add:  $NodesToAdd"
Write-Host "  Nodes to Remove: $NodesToRemove"
Write-Host "  Degree: $Degree"
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# Step 1: Start fresh cluster
Write-Status "Step 1: Starting fresh $Protocol cluster with $InitialNodes nodes"
Push-Location $LocalstackDir

# Stop any existing cluster
docker-compose down 2>&1 | Out-Null

# Generate new cluster
& .\generate-docker-compose.ps1 -Nodes $InitialNodes -Degree $Degree -Protocol $Protocol -CacheEnabled $false

# Start cluster
& .\start.ps1
Wait-ForStabilization -Seconds 45

Pop-Location

# Step 2: Baseline benchmark (stable cluster)
Write-Status "Step 2: Baseline benchmark (stable cluster)"
$Results += Run-Benchmark -Phase "Baseline-Cold"
$Results += Run-Benchmark -Phase "Baseline-Warm"

# Step 3: Add nodes and measure
Write-Status "Step 3: Adding $NodesToAdd nodes and measuring impact"
$addStabilizationStart = Get-Date
Add-Nodes -Count $NodesToAdd
$addStabilizationTime = Measure-StabilizationTime -Phase "After-Add"
$Results += [PSCustomObject]@{
    Protocol = $Protocol
    Phase = "Stabilization-Add"
    Nodes = $InitialNodes + $NodesToAdd
    Requests = 0
    P50_ms = 0
    P99_ms = 0
    SuccessRate = 0
    HitRate = 0
    Errors = 0
    Duration_s = $addStabilizationTime
    Timestamp = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
}

# Benchmark after add
$Results += Run-Benchmark -Phase "After-Add-Cold"
$Results += Run-Benchmark -Phase "After-Add-Warm"

# Step 4: Remove nodes and measure
Write-Status "Step 4: Removing $NodesToRemove nodes and measuring impact"
$removeStabilizationStart = Get-Date
Remove-Nodes -Count $NodesToRemove
$removeStabilizationTime = Measure-StabilizationTime -Phase "After-Remove"
$Results += [PSCustomObject]@{
    Protocol = $Protocol
    Phase = "Stabilization-Remove"
    Nodes = $InitialNodes + $NodesToAdd - $NodesToRemove
    Requests = 0
    P50_ms = 0
    P99_ms = 0
    SuccessRate = 0
    HitRate = 0
    Errors = 0
    Duration_s = $removeStabilizationTime
    Timestamp = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
}

# Benchmark after remove
$Results += Run-Benchmark -Phase "After-Remove-Cold"
$Results += Run-Benchmark -Phase "After-Remove-Warm"

# Step 5: Churn during load (optional stress test)
Write-Status "Step 5: Testing performance DURING node churn"
$Results += Run-ConcurrentBenchmarkDuringChurn -ChurnType "add" -NodeCount 2
Wait-ForStabilization -Seconds 15
$Results += Run-ConcurrentBenchmarkDuringChurn -ChurnType "remove" -NodeCount 2

# Save results
$Results | Export-Csv -Path $ResultsFile -NoTypeInformation
Write-Status "Results saved to: $ResultsFile" -Color Green

# Print summary
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  TEST SUMMARY: $($Protocol.ToUpper())" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Stabilization Times:" -ForegroundColor Yellow
Write-Host "  After Adding $NodesToAdd nodes:    ${addStabilizationTime}s"
Write-Host "  After Removing $NodesToRemove nodes: ${removeStabilizationTime}s"
Write-Host ""
Write-Host "Performance (Warm Cache):" -ForegroundColor Yellow
$Results | Where-Object { $_.Phase -like "*-Warm" } | ForEach-Object {
    Write-Host "  $($_.Phase): P50=$($_.P50_ms)ms, P99=$($_.P99_ms)ms, Errors=$($_.Errors)"
}
Write-Host ""
Write-Host "Errors During Churn:" -ForegroundColor Yellow
$Results | Where-Object { $_.Phase -like "During-*" } | ForEach-Object {
    Write-Host "  $($_.Phase): $($_.Errors) errors"
}
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan

Write-Status "Test complete! Run with other protocol to compare." -Color Green
Write-Host "  Compare: .\test-membership-churn.ps1 -Protocol $(if ($Protocol -eq 'chord') {'koorde'} else {'chord'})"
