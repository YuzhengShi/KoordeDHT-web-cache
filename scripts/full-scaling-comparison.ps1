# Full Scaling Comparison: Chord vs Koorde at Different Scales
# Tests both protocols across multiple node counts
# Usage: .\full-scaling-comparison.ps1

param(
    [switch]$SkipBuild = $false,
    [int]$RequestsPerTest = 150,
    [int]$RequestRate = 75
)

$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "     FULL SCALING COMPARISON: CHORD vs KOORDE" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""

# Test matrix
$testMatrix = @(
    @{Nodes=4;  Degree=2; Description="Small cluster, low degree"},
    @{Nodes=4;  Degree=4; Description="Small cluster, high degree"},
    @{Nodes=8;  Degree=2; Description="Medium cluster, low degree"},
    @{Nodes=8;  Degree=4; Description="Medium cluster, medium degree"},
    @{Nodes=8;  Degree=8; Description="Medium cluster, high degree"},
    @{Nodes=16; Degree=4; Description="Large cluster, medium degree"},
    @{Nodes=16; Degree=8; Description="Large cluster, high degree"}
)

# Build if needed
if (-not $SkipBuild) {
    Write-Host "[BUILD] Compiling binaries..." -ForegroundColor Gray
    go build -o bin/koorde-node.exe ./cmd/node 2>&1 | Out-Null
    go build -o bin/cache-workload.exe ./cmd/cache-workload 2>&1 | Out-Null
    Write-Host "  Done." -ForegroundColor Green
}

# Create directories
New-Item -ItemType Directory -Path "logs" -Force | Out-Null
New-Item -ItemType Directory -Path "benchmark/results" -Force | Out-Null

$allResults = @()

function Stop-AllNodes {
    Get-Process -Name "koorde-node" -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 2
}

function Start-Cluster {
    param([int]$NodeCount, [string]$ConfigDir)
    
    Start-Process -FilePath ".\bin\koorde-node.exe" `
        -ArgumentList "-config", "$ConfigDir/node0.yaml" `
        -RedirectStandardOutput "logs/scale-node0.log" `
        -RedirectStandardError "logs/scale-node0.err" `
        -WindowStyle Hidden
    
    Start-Sleep -Seconds 3
    
    for ($i = 1; $i -lt $NodeCount; $i++) {
        Start-Process -FilePath ".\bin\koorde-node.exe" `
            -ArgumentList "-config", "$ConfigDir/node$i.yaml" `
            -RedirectStandardOutput "logs/scale-node$i.log" `
            -RedirectStandardError "logs/scale-node$i.err" `
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
            Avg = [Math]::Round(($latencies | Measure-Object -Average).Average, 2)
            P99 = [Math]::Round($sorted[[Math]::Floor($count * 0.99)], 2)
            Success = [Math]::Round($successes / $Reqs * 100, 1)
        }
    }
    return @{Avg=0; P99=0; Success=0}
}

function Get-DBUsage {
    param([int]$NodeCount)
    
    $totalDB = 0
    $totalSucc = 0
    
    for ($i = 0; $i -lt $NodeCount; $i++) {
        try {
            $m = Invoke-RestMethod "http://localhost:$(8080+$i)/metrics" -TimeoutSec 3
            $totalDB += $m.routing.stats.de_bruijn_success
            $totalSucc += $m.routing.stats.successor_fallbacks
        } catch {}
    }
    
    $total = $totalDB + $totalSucc
    return if ($total -gt 0) { [Math]::Round($totalDB / $total * 100, 1) } else { 0 }
}

Write-Host ""
$testNum = 0
$totalTests = $testMatrix.Count * 2

foreach ($config in $testMatrix) {
    $nodes = $config.Nodes
    $degree = $config.Degree
    
    $m = [Math]::Ceiling([Math]::Log($nodes) / [Math]::Log(2))
    $logD = [Math]::Max(1, [Math]::Log($degree) / [Math]::Log(2))
    $koordeHops = [Math]::Ceiling($m / $logD)
    
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host "  $($config.Description)" -ForegroundColor Cyan
    Write-Host "  Nodes: $nodes | Degree: $degree | Hops: Chord ~$m, Koorde ~$koordeHops" -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan
    
    # --- CHORD ---
    $testNum++
    Write-Host "[$testNum/$totalTests] Testing CHORD..." -ForegroundColor Yellow
    
    Stop-AllNodes
    & ./scripts/generate-chord-configs.ps1 -Nodes $nodes -OutputDir "config/chord-cluster" | Out-Null
    Start-Cluster -NodeCount $nodes -ConfigDir "config/chord-cluster"
    Start-Sleep -Seconds 12
    
    if (Wait-ForReady -NodeCount $nodes -TimeoutSec 45) {
        $chordResult = Run-Workload -NodeCount $nodes -Reqs $RequestsPerTest -ReqRate $RequestRate -OutputFile "benchmark/results/temp-chord.csv"
        Write-Host "    Chord: Avg=$($chordResult.Avg)ms, P99=$($chordResult.P99)ms" -ForegroundColor Gray
    } else {
        Write-Host "    Chord: FAILED TO START" -ForegroundColor Red
        $chordResult = @{Avg=0; P99=0; Success=0}
    }
    
    Stop-AllNodes
    
    # --- KOORDE ---
    $testNum++
    Write-Host "[$testNum/$totalTests] Testing KOORDE..." -ForegroundColor Yellow
    
    & ./scripts/generate-cluster-configs.ps1 -Nodes $nodes -Degree $degree -OutputDir "config/test-cluster" | Out-Null
    Start-Cluster -NodeCount $nodes -ConfigDir "config/test-cluster"
    Start-Sleep -Seconds 12
    
    if (Wait-ForReady -NodeCount $nodes -TimeoutSec 45) {
        $koordeResult = Run-Workload -NodeCount $nodes -Reqs $RequestsPerTest -ReqRate $RequestRate -OutputFile "benchmark/results/temp-koorde.csv"
        $dbUsage = Get-DBUsage -NodeCount $nodes
        Write-Host "    Koorde: Avg=$($koordeResult.Avg)ms, P99=$($koordeResult.P99)ms, DB=$dbUsage%" -ForegroundColor Gray
    } else {
        Write-Host "    Koorde: FAILED TO START" -ForegroundColor Red
        $koordeResult = @{Avg=0; P99=0; Success=0}
        $dbUsage = 0
    }
    
    Stop-AllNodes
    
    # Calculate improvement
    $avgImprove = if ($chordResult.Avg -gt 0) {
        [Math]::Round(($chordResult.Avg - $koordeResult.Avg) / $chordResult.Avg * 100, 1)
    } else { 0 }
    
    $p99Improve = if ($chordResult.P99 -gt 0) {
        [Math]::Round(($chordResult.P99 - $koordeResult.P99) / $chordResult.P99 * 100, 1)
    } else { 0 }
    
    $winner = if ($koordeResult.Avg -lt $chordResult.Avg) { "Koorde" } else { "Chord" }
    
    $allResults += [PSCustomObject]@{
        Nodes = $nodes
        Degree = $degree
        ChordHops = $m
        KoordeHops = $koordeHops
        ChordAvg = $chordResult.Avg
        KoordeAvg = $koordeResult.Avg
        AvgImprove = "$avgImprove%"
        ChordP99 = $chordResult.P99
        KoordeP99 = $koordeResult.P99
        P99Improve = "$p99Improve%"
        DBUsage = "$dbUsage%"
        Winner = $winner
    }
    
    Write-Host ""
}

# Final Summary
Write-Host ""
Write-Host "================================================================" -ForegroundColor Green
Write-Host "                    FINAL RESULTS SUMMARY" -ForegroundColor Green
Write-Host "================================================================" -ForegroundColor Green
Write-Host ""

$allResults | Format-Table -Property Nodes, Degree, ChordHops, KoordeHops, ChordAvg, KoordeAvg, AvgImprove, DBUsage, Winner -AutoSize

Write-Host ""
Write-Host "Legend:" -ForegroundColor Cyan
Write-Host "  ChordHops/KoordeHops: Theoretical routing hops"
Write-Host "  ChordAvg/KoordeAvg: Average latency in milliseconds"
Write-Host "  AvgImprove: Percentage improvement (positive = Koorde faster)"
Write-Host "  DBUsage: Percentage of hops using de Bruijn routing"
Write-Host ""

# Save results
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$resultsFile = "benchmark/results/full-comparison-$timestamp.csv"
$allResults | Export-Csv -Path $resultsFile -NoTypeInformation
Write-Host "Results saved to: $resultsFile" -ForegroundColor Gray

# Analysis
Write-Host ""
Write-Host "KEY INSIGHTS:" -ForegroundColor Yellow
Write-Host "------------------------------------------------------------"

$koordeWins = ($allResults | Where-Object { $_.Winner -eq "Koorde" }).Count
$total = $allResults.Count
Write-Host "  Koorde won $koordeWins out of $total tests"

$bestImprove = $allResults | Sort-Object { [double]($_.AvgImprove -replace '%','') } -Descending | Select-Object -First 1
Write-Host "  Best Koorde improvement: $($bestImprove.AvgImprove) at $($bestImprove.Nodes) nodes, degree=$($bestImprove.Degree)"

$highestDB = $allResults | Sort-Object { [double]($_.DBUsage -replace '%','') } -Descending | Select-Object -First 1
Write-Host "  Highest de Bruijn usage: $($highestDB.DBUsage) at $($highestDB.Nodes) nodes, degree=$($highestDB.Degree)"

Write-Host "------------------------------------------------------------"
Write-Host ""
