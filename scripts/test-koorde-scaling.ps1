# Comprehensive Koorde Scaling Test
# Tests different combinations of node counts and de Bruijn degrees
# Usage: .\test-koorde-scaling.ps1

param(
    [switch]$SkipBuild = $false,
    [int]$RequestsPerTest = 200,
    [int]$RequestRate = 100
)

$ErrorActionPreference = "Stop"

Write-Host @"
╔══════════════════════════════════════════════════════════════╗
║           Koorde De Bruijn Scaling Test Suite                ║
╠══════════════════════════════════════════════════════════════╣
║  Tests how Koorde performance scales with:                   ║
║    - Different node counts (4, 8, 16 nodes)                  ║
║    - Different de Bruijn degrees (2, 4, 8)                   ║
╚══════════════════════════════════════════════════════════════╝
"@ -ForegroundColor Cyan

# Test configurations: [nodes, degree]
$testConfigs = @(
    @{Nodes=4;  Degree=2},   # Small cluster, low degree
    @{Nodes=4;  Degree=4},   # Small cluster, high degree
    @{Nodes=8;  Degree=2},   # Medium cluster, low degree
    @{Nodes=8;  Degree=4},   # Medium cluster, medium degree
    @{Nodes=16; Degree=2},   # Large cluster, low degree
    @{Nodes=16; Degree=4},   # Large cluster, medium degree
    @{Nodes=16; Degree=8}    # Large cluster, high degree
)

$results = @()

# Build if needed
if (-not $SkipBuild) {
    Write-Host "`n[BUILD] Compiling koorde-node and cache-workload..." -ForegroundColor Yellow
    go build -o bin/koorde-node.exe ./cmd/node
    go build -o bin/cache-workload.exe ./cmd/cache-workload
}

function Stop-AllNodes {
    Write-Host "  Stopping all nodes..." -ForegroundColor Gray
    Get-Process -Name "koorde-node" -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 2
}

function Start-Cluster {
    param([int]$NodeCount, [string]$ConfigDir)
    
    Write-Host "  Starting $NodeCount nodes..." -ForegroundColor Gray
    
    # Start node 0 first (no bootstrap)
    $logFile = "logs/scale-test-node0.log"
    Start-Process -FilePath ".\bin\koorde-node.exe" `
        -ArgumentList "-config", "$ConfigDir/node0.yaml" `
        -RedirectStandardOutput $logFile `
        -RedirectStandardError "$logFile.err" `
        -WindowStyle Hidden
    
    Start-Sleep -Seconds 3
    
    # Start remaining nodes
    for ($i = 1; $i -lt $NodeCount; $i++) {
        $logFile = "logs/scale-test-node$i.log"
        Start-Process -FilePath ".\bin\koorde-node.exe" `
            -ArgumentList "-config", "$ConfigDir/node$i.yaml" `
            -RedirectStandardOutput $logFile `
            -RedirectStandardError "$logFile.err" `
            -WindowStyle Hidden
        
        # Stagger starts slightly
        Start-Sleep -Milliseconds 500
    }
    
    # Wait for cluster to stabilize
    Write-Host "  Waiting for cluster stabilization..." -ForegroundColor Gray
    Start-Sleep -Seconds 10
}

function Wait-ForClusterReady {
    param([int]$NodeCount, [int]$TimeoutSeconds = 60)
    
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    
    while ((Get-Date) -lt $deadline) {
        $readyCount = 0
        for ($i = 0; $i -lt $NodeCount; $i++) {
            $port = 8080 + $i
            try {
                $health = Invoke-RestMethod "http://localhost:$port/health" -TimeoutSec 2
                if ($health.status -eq "READY") {
                    $readyCount++
                }
            } catch {
                # Node not ready yet
            }
        }
        
        if ($readyCount -eq $NodeCount) {
            Write-Host "  All $NodeCount nodes READY!" -ForegroundColor Green
            return $true
        }
        
        Write-Host "  Waiting... ($readyCount/$NodeCount ready)" -ForegroundColor Gray
        Start-Sleep -Seconds 2
    }
    
    Write-Host "  WARNING: Timeout waiting for cluster" -ForegroundColor Yellow
    return $false
}

function Get-ClusterMetrics {
    param([int]$NodeCount)
    
    $totalDeBruijnSuccess = 0
    $totalSuccessorFallback = 0
    $totalDeBruijnEntries = 0
    
    for ($i = 0; $i -lt $NodeCount; $i++) {
        $port = 8080 + $i
        try {
            $metrics = Invoke-RestMethod "http://localhost:$port/metrics" -TimeoutSec 5
            $totalDeBruijnSuccess += $metrics.routing.stats.de_bruijn_success
            $totalSuccessorFallback += $metrics.routing.stats.successor_fallbacks
            $totalDeBruijnEntries += $metrics.routing.debruijn_count
        } catch {
            Write-Host "  Warning: Could not get metrics from node $i" -ForegroundColor Yellow
        }
    }
    
    return @{
        DeBruijnSuccess = $totalDeBruijnSuccess
        SuccessorFallback = $totalSuccessorFallback
        AvgDeBruijnEntries = [Math]::Round($totalDeBruijnEntries / $NodeCount, 2)
    }
}

function Run-Workload {
    param([int]$NodeCount, [int]$Requests, [int]$Rate)
    
    # Build targets list for load balancing
    $targets = @()
    for ($i = 0; $i -lt $NodeCount; $i++) {
        $targets += "http://localhost:$(8080 + $i)"
    }
    $targetStr = $targets -join ","
    
    $outputFile = "results-temp.csv"
    
    & ./bin/cache-workload.exe `
        -targets $targetStr `
        -requests $Requests `
        -rate $Rate `
        -urls 500 `
        -output $outputFile
    
    # Parse results
    if (Test-Path $outputFile) {
        $csv = Import-Csv $outputFile
        $latencies = $csv | ForEach-Object { [double]$_.latency_ms }
        $successes = ($csv | Where-Object { $_.status -eq "success" }).Count
        
        $sorted = $latencies | Sort-Object
        $p50 = $sorted[[Math]::Floor($sorted.Count * 0.50)]
        $p99 = $sorted[[Math]::Floor($sorted.Count * 0.99)]
        $avg = ($latencies | Measure-Object -Average).Average
        
        Remove-Item $outputFile -Force
        
        return @{
            AvgLatency = [Math]::Round($avg, 2)
            P50Latency = [Math]::Round($p50, 2)
            P99Latency = [Math]::Round($p99, 2)
            SuccessRate = [Math]::Round($successes / $Requests * 100, 2)
        }
    }
    
    return $null
}

# Create logs directory
New-Item -ItemType Directory -Path "logs" -Force | Out-Null

Write-Host "`n[TEST] Running scaling tests..." -ForegroundColor Yellow
Write-Host ""

foreach ($config in $testConfigs) {
    $nodes = $config.Nodes
    $degree = $config.Degree
    
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
    Write-Host "Testing: $nodes nodes, degree=$degree" -ForegroundColor Cyan
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
    
    # Calculate theoretical hops
    $m = [Math]::Ceiling([Math]::Log($nodes) / [Math]::Log(2))
    $logD = [Math]::Max(1, [Math]::Log($degree) / [Math]::Log(2))
    $chordHops = $m
    $koordeHops = [Math]::Ceiling($m / $logD)
    
    Write-Host "  Theoretical: Chord ~$chordHops hops, Koorde ~$koordeHops hops"
    
    # Stop any existing nodes
    Stop-AllNodes
    
    # Generate config
    Write-Host "  Generating configuration..." -ForegroundColor Gray
    & ./scripts/generate-cluster-configs.ps1 -Nodes $nodes -Degree $degree -OutputDir "config/test-cluster" | Out-Null
    
    # Start cluster
    Start-Cluster -NodeCount $nodes -ConfigDir "config/test-cluster"
    
    # Wait for ready
    $ready = Wait-ForClusterReady -NodeCount $nodes -TimeoutSeconds 60
    if (-not $ready) {
        Write-Host "  SKIPPING: Cluster not ready" -ForegroundColor Red
        continue
    }
    
    # Get baseline metrics
    $metricsBefore = Get-ClusterMetrics -NodeCount $nodes
    
    # Run workload
    Write-Host "  Running workload ($RequestsPerTest requests @ $RequestRate req/s)..." -ForegroundColor Gray
    $workloadResult = Run-Workload -NodeCount $nodes -Requests $RequestsPerTest -Rate $RequestRate
    
    # Get final metrics
    $metricsAfter = Get-ClusterMetrics -NodeCount $nodes
    
    # Calculate delta
    $deBruijnDelta = $metricsAfter.DeBruijnSuccess - $metricsBefore.DeBruijnSuccess
    $successorDelta = $metricsAfter.SuccessorFallback - $metricsBefore.SuccessorFallback
    $deBruijnRatio = if (($deBruijnDelta + $successorDelta) -gt 0) {
        [Math]::Round($deBruijnDelta / ($deBruijnDelta + $successorDelta) * 100, 1)
    } else { 0 }
    
    # Store result
    $result = [PSCustomObject]@{
        Nodes = $nodes
        Degree = $degree
        TheoreticalChordHops = $chordHops
        TheoreticalKoordeHops = $koordeHops
        AvgLatencyMs = $workloadResult.AvgLatency
        P50LatencyMs = $workloadResult.P50Latency
        P99LatencyMs = $workloadResult.P99Latency
        SuccessRate = $workloadResult.SuccessRate
        DeBruijnUsage = "$deBruijnRatio%"
        AvgDeBruijnEntries = $metricsAfter.AvgDeBruijnEntries
    }
    $results += $result
    
    Write-Host ""
    Write-Host "  Results:" -ForegroundColor Green
    Write-Host "    Avg Latency:     $($workloadResult.AvgLatency) ms"
    Write-Host "    P50 Latency:     $($workloadResult.P50Latency) ms"
    Write-Host "    P99 Latency:     $($workloadResult.P99Latency) ms"
    Write-Host "    Success Rate:    $($workloadResult.SuccessRate)%"
    Write-Host "    De Bruijn Usage: $deBruijnRatio%"
    Write-Host "    Avg DB Entries:  $($metricsAfter.AvgDeBruijnEntries)"
    Write-Host ""
}

# Stop cluster
Stop-AllNodes

# Summary
Write-Host ""
Write-Host "╔══════════════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║                    SCALING TEST RESULTS                      ║" -ForegroundColor Green
Write-Host "╚══════════════════════════════════════════════════════════════╝" -ForegroundColor Green
Write-Host ""

$results | Format-Table -AutoSize

# Save results
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$resultsFile = "benchmark/results/scaling-test-$timestamp.csv"
$results | Export-Csv -Path $resultsFile -NoTypeInformation
Write-Host "Results saved to: $resultsFile" -ForegroundColor Cyan

# Analysis
Write-Host ""
Write-Host "═══ ANALYSIS ═══" -ForegroundColor Yellow
Write-Host ""
Write-Host "Key observations to look for:" -ForegroundColor Cyan
Write-Host "  1. De Bruijn Usage should increase with more nodes (longer routes need more hops)"
Write-Host "  2. Higher degree should reduce average latency (fewer hops needed)"
Write-Host "  3. Avg DB Entries should approach the configured degree"
Write-Host "  4. P99 latency should be more stable with higher degree"
Write-Host ""
