# Comprehensive Chord vs Koorde Comparison Test
# Runs both protocols with the same node count and compares performance
# Usage: .\compare-chord-koorde.ps1 -Nodes 8 -Degree 4

param(
    [int]$Nodes = 8,
    [int]$Degree = 4,
    [int]$Requests = 200,
    [int]$Rate = 100,
    [switch]$SkipBuild = $false
)

$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "       CHORD vs KOORDE COMPARISON TEST" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Configuration:" -ForegroundColor Yellow
Write-Host "  Nodes:    $Nodes"
Write-Host "  Degree:   $Degree (Koorde only)"
Write-Host "  Requests: $Requests"
Write-Host "  Rate:     $Rate req/s"
Write-Host ""

# Calculate theoretical hops
$m = [Math]::Ceiling([Math]::Log($Nodes) / [Math]::Log(2))
$logD = [Math]::Max(1, [Math]::Log($Degree) / [Math]::Log(2))
$koordeHops = [Math]::Ceiling($m / $logD)

Write-Host "Theoretical Routing:" -ForegroundColor Yellow
Write-Host "  Chord:  O(log n) = ~$m hops"
Write-Host "  Koorde: O(log n / log d) = ~$koordeHops hops"
Write-Host ""

# Build if needed
if (-not $SkipBuild) {
    Write-Host "[BUILD] Compiling binaries..." -ForegroundColor Gray
    go build -o bin/koorde-node.exe ./cmd/node 2>&1 | Out-Null
    go build -o bin/cache-workload.exe ./cmd/cache-workload 2>&1 | Out-Null
    Write-Host "  Done." -ForegroundColor Green
    Write-Host ""
}

# Create directories
New-Item -ItemType Directory -Path "logs" -Force | Out-Null
New-Item -ItemType Directory -Path "benchmark/results" -Force | Out-Null

function Stop-AllNodes {
    Get-Process -Name "koorde-node" -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 2
}

function Start-Cluster {
    param([int]$NodeCount, [string]$ConfigDir)
    
    # Start node 0 first
    Start-Process -FilePath ".\bin\koorde-node.exe" `
        -ArgumentList "-config", "$ConfigDir/node0.yaml" `
        -RedirectStandardOutput "logs/compare-node0.log" `
        -RedirectStandardError "logs/compare-node0.err" `
        -WindowStyle Hidden
    
    Start-Sleep -Seconds 3
    
    # Start remaining nodes
    for ($i = 1; $i -lt $NodeCount; $i++) {
        Start-Process -FilePath ".\bin\koorde-node.exe" `
            -ArgumentList "-config", "$ConfigDir/node$i.yaml" `
            -RedirectStandardOutput "logs/compare-node$i.log" `
            -RedirectStandardError "logs/compare-node$i.err" `
            -WindowStyle Hidden
        Start-Sleep -Milliseconds 300
    }
}

function Wait-ForReady {
    param([int]$NodeCount, [int]$TimeoutSec = 60)
    
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        $ready = 0
        for ($i = 0; $i -lt $NodeCount; $i++) {
            try {
                $h = Invoke-RestMethod "http://localhost:$(8080+$i)/health" -TimeoutSec 2
                if ($h.status -eq "READY") { $ready++ }
            } catch {}
        }
        if ($ready -eq $NodeCount) { return $true }
        Start-Sleep -Seconds 2
    }
    return $false
}

function Run-Workload {
    param([int]$NodeCount, [int]$Reqs, [int]$ReqRate, [string]$OutputFile)
    
    $targets = @()
    for ($i = 0; $i -lt $NodeCount; $i++) {
        $targets += "http://localhost:$(8080+$i)"
    }
    $targetsStr = $targets -join ','
    
    & ./bin/cache-workload.exe -targets $targetsStr -requests $Reqs -rate $ReqRate -urls 300 -output $OutputFile 2>&1 | Out-Null
    
    if (Test-Path $OutputFile) {
        $csv = Import-Csv $OutputFile
        $latencies = $csv | ForEach-Object { [double]$_.latency_ms }
        # Status is HTTP code (200 = success)
        $successes = ($csv | Where-Object { $_.status -eq "200" }).Count
        
        $sorted = $latencies | Sort-Object
        $count = $sorted.Count
        
        return @{
            AvgLatency = [Math]::Round(($latencies | Measure-Object -Average).Average, 2)
            P50 = [Math]::Round($sorted[[Math]::Floor($count * 0.50)], 2)
            P95 = [Math]::Round($sorted[[Math]::Floor($count * 0.95)], 2)
            P99 = [Math]::Round($sorted[[Math]::Floor($count * 0.99)], 2)
            SuccessRate = [Math]::Round($successes / $Reqs * 100, 2)
            Total = $count
        }
    }
    return $null
}

function Get-RoutingStats {
    param([int]$NodeCount)
    
    $totalDB = 0
    $totalSucc = 0
    $totalEntries = 0
    $protocol = ""
    
    for ($i = 0; $i -lt $NodeCount; $i++) {
        try {
            $m = Invoke-RestMethod "http://localhost:$(8080+$i)/metrics" -TimeoutSec 3
            $totalDB += $m.routing.stats.de_bruijn_success
            $totalSucc += $m.routing.stats.successor_fallbacks
            $totalEntries += $m.routing.debruijn_count
            $protocol = $m.routing.stats.protocol
        } catch {}
    }
    
    $total = $totalDB + $totalSucc
    $ratio = if ($total -gt 0) { [Math]::Round($totalDB / $total * 100, 1) } else { 0 }
    
    return @{
        Protocol = $protocol
        DeBruijnSuccess = $totalDB
        SuccessorFallback = $totalSucc
        DeBruijnUsage = $ratio
        AvgEntries = [Math]::Round($totalEntries / $NodeCount, 1)
    }
}

# ============================================================
# INITIAL CLEANUP - Kill any stale processes from previous runs
# ============================================================
Write-Host "[CLEANUP] Stopping any existing nodes..." -ForegroundColor Gray
Stop-AllNodes

# ============================================================
# TEST 1: CHORD
# ============================================================
Write-Host "------------------------------------------------------------" -ForegroundColor Gray
Write-Host "[TEST 1] Running CHORD with $Nodes nodes..." -ForegroundColor Yellow
Write-Host "------------------------------------------------------------" -ForegroundColor Gray

Write-Host "  Generating Chord config..." -ForegroundColor Gray
& ./scripts/generate-chord-configs.ps1 -Nodes $Nodes -OutputDir "config/chord-cluster" | Out-Null

Write-Host "  Starting Chord cluster..." -ForegroundColor Gray
Start-Cluster -NodeCount $Nodes -ConfigDir "config/chord-cluster"

Write-Host "  Waiting for cluster ready..." -ForegroundColor Gray
Start-Sleep -Seconds 20
$chordReady = Wait-ForReady -NodeCount $Nodes -TimeoutSec 45

if (-not $chordReady) {
    Write-Host "  ERROR: Chord cluster not ready!" -ForegroundColor Red
    Stop-AllNodes
    exit 1
}
Write-Host "  Chord cluster READY" -ForegroundColor Green

Write-Host "  Running workload..." -ForegroundColor Gray
$chordResult = Run-Workload -NodeCount $Nodes -Reqs $Requests -ReqRate $Rate -OutputFile "benchmark/results/chord-compare.csv"
$chordStats = Get-RoutingStats -NodeCount $Nodes

Stop-AllNodes
Write-Host "  Chord test complete." -ForegroundColor Green
Write-Host ""

# ============================================================
# TEST 2: KOORDE
# ============================================================
Write-Host "------------------------------------------------------------" -ForegroundColor Gray
Write-Host "[TEST 2] Running KOORDE with $Nodes nodes, degree=$Degree..." -ForegroundColor Yellow
Write-Host "------------------------------------------------------------" -ForegroundColor Gray

Write-Host "  Generating Koorde config..." -ForegroundColor Gray
& ./scripts/generate-cluster-configs.ps1 -Nodes $Nodes -Degree $Degree -OutputDir "config/test-cluster" | Out-Null

Write-Host "  Starting Koorde cluster..." -ForegroundColor Gray
Start-Cluster -NodeCount $Nodes -ConfigDir "config/test-cluster"

Write-Host "  Waiting for cluster ready..." -ForegroundColor Gray
Start-Sleep -Seconds 20
$koordeReady = Wait-ForReady -NodeCount $Nodes -TimeoutSec 45

if (-not $koordeReady) {
    Write-Host "  ERROR: Koorde cluster not ready!" -ForegroundColor Red
    Stop-AllNodes
    exit 1
}
Write-Host "  Koorde cluster READY" -ForegroundColor Green

Write-Host "  Running workload..." -ForegroundColor Gray
$koordeResult = Run-Workload -NodeCount $Nodes -Reqs $Requests -ReqRate $Rate -OutputFile "benchmark/results/koorde-compare.csv"
$koordeStats = Get-RoutingStats -NodeCount $Nodes

Stop-AllNodes
Write-Host "  Koorde test complete." -ForegroundColor Green
Write-Host ""

# ============================================================
# RESULTS
# ============================================================
Write-Host "============================================================" -ForegroundColor Green
Write-Host "                    COMPARISON RESULTS" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host ""
Write-Host "Test Configuration:" -ForegroundColor Cyan
Write-Host "  Nodes: $Nodes | Koorde Degree: $Degree | Requests: $Requests"
Write-Host ""
Write-Host "Theoretical Hops: Chord ~$m | Koorde ~$koordeHops"
Write-Host ""

# Latency comparison
Write-Host "LATENCY COMPARISON:" -ForegroundColor Yellow
Write-Host "------------------------------------------------------------"
Write-Host ("{0,-15} {1,12} {2,12} {3,12}" -f "Metric", "Chord", "Koorde", "Improvement")
Write-Host "------------------------------------------------------------"

$metrics = @(
    @{Name="Avg Latency"; Chord=$chordResult.AvgLatency; Koorde=$koordeResult.AvgLatency},
    @{Name="P50 Latency"; Chord=$chordResult.P50; Koorde=$koordeResult.P50},
    @{Name="P95 Latency"; Chord=$chordResult.P95; Koorde=$koordeResult.P95},
    @{Name="P99 Latency"; Chord=$chordResult.P99; Koorde=$koordeResult.P99}
)

foreach ($metric in $metrics) {
    $improvement = if ($metric.Chord -gt 0) {
        [Math]::Round(($metric.Chord - $metric.Koorde) / $metric.Chord * 100, 1)
    } else { 0 }
    
    $impStr = if ($improvement -gt 0) { "+$improvement%" } else { "$improvement%" }
    $color = if ($improvement -gt 0) { "Green" } else { "Red" }
    
    $line = "{0,-15} {1,10} ms {2,10} ms" -f $metric.Name, $metric.Chord, $metric.Koorde
    Write-Host $line -NoNewline
    Write-Host ("{0,12}" -f $impStr) -ForegroundColor $color
}

Write-Host "------------------------------------------------------------"
Write-Host ""

# Success rate
Write-Host "SUCCESS RATE:" -ForegroundColor Yellow
Write-Host "  Chord:  $($chordResult.SuccessRate)%"
Write-Host "  Koorde: $($koordeResult.SuccessRate)%"
Write-Host ""

# Routing stats
Write-Host "ROUTING STATISTICS:" -ForegroundColor Yellow
Write-Host "  Chord:"
Write-Host "    Protocol: $($chordStats.Protocol)"
Write-Host "    De Bruijn Usage: N/A (Chord uses finger tables)"
Write-Host ""
Write-Host "  Koorde:"
Write-Host "    Protocol: $($koordeStats.Protocol)"
Write-Host "    De Bruijn Success: $($koordeStats.DeBruijnSuccess)"
Write-Host "    Successor Fallback: $($koordeStats.SuccessorFallback)"
Write-Host "    De Bruijn Usage: $($koordeStats.DeBruijnUsage)%"
Write-Host "    Avg DB Entries: $($koordeStats.AvgEntries) (target: $Degree)"
Write-Host ""

# Winner
Write-Host "============================================================" -ForegroundColor Cyan
if ($koordeResult.AvgLatency -lt $chordResult.AvgLatency) {
    $winner = "KOORDE"
    $winColor = "Green"
    $diff = [Math]::Round(($chordResult.AvgLatency - $koordeResult.AvgLatency) / $chordResult.AvgLatency * 100, 1)
    $summary = "Koorde is $diff% faster on average"
} else {
    $winner = "CHORD"
    $winColor = "Yellow"
    $diff = [Math]::Round(($koordeResult.AvgLatency - $chordResult.AvgLatency) / $koordeResult.AvgLatency * 100, 1)
    $summary = "Chord is $diff% faster on average"
}
Write-Host "  WINNER: $winner" -ForegroundColor $winColor
Write-Host "  $summary"
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

# Save summary
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$summaryFile = "benchmark/results/comparison-$Nodes-nodes-$timestamp.txt"

@"
Chord vs Koorde Comparison
==========================
Date: $(Get-Date)
Nodes: $Nodes
Koorde Degree: $Degree
Requests: $Requests
Rate: $Rate req/s

Theoretical Hops:
  Chord:  ~$m
  Koorde: ~$koordeHops

Latency Results:
  Metric          Chord       Koorde
  Avg Latency     $($chordResult.AvgLatency) ms    $($koordeResult.AvgLatency) ms
  P50 Latency     $($chordResult.P50) ms    $($koordeResult.P50) ms
  P95 Latency     $($chordResult.P95) ms    $($koordeResult.P95) ms
  P99 Latency     $($chordResult.P99) ms    $($koordeResult.P99) ms

Success Rate:
  Chord:  $($chordResult.SuccessRate)%
  Koorde: $($koordeResult.SuccessRate)%

Koorde Routing:
  De Bruijn Usage: $($koordeStats.DeBruijnUsage)%
  Avg DB Entries: $($koordeStats.AvgEntries)

Winner: $winner
"@ | Out-File -FilePath $summaryFile -Encoding UTF8

Write-Host "Results saved to: $summaryFile" -ForegroundColor Gray
