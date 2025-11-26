# Comprehensive Chord vs Koorde Benchmark Suite
# Tests multiple node counts and degrees, generates comparison matrix
# Usage: .\comprehensive-benchmark.ps1 [-QuickTest] [-OutputDir "benchmark/results"]

param(
    [switch]$QuickTest = $false,
    [string]$OutputDir = "benchmark/results/comprehensive",
    [int]$WarmupRequests = 50,
    [int]$Requests = 300,
    [int]$Rate = 100,
    [int]$StabilizationTime = 25,
    [switch]$SkipBuild = $false,
    [int[]]$NodeCounts = @(),
    [int[]]$Degrees = @(),
    [string[]]$Protocols = @("chord", "koorde"),
    [int]$SimulatedLatencyMs = 0  # 0 = no latency, >0 = inject N ms per hop
)

$ErrorActionPreference = "Stop"

# ============================================================
# CONFIGURATION MATRIX
# ============================================================

# Use defaults if not specified
$DefaultNodeCounts = @(8, 16, 32)
$DefaultDegrees = @(2, 4, 8)

if ($NodeCounts.Count -eq 0) { $NodeCounts = $DefaultNodeCounts }
if ($Degrees.Count -eq 0) { $Degrees = $DefaultDegrees }

if ($QuickTest) {
    $Requests = 100
    $WarmupRequests = 20
    $StabilizationTime = 15
    Write-Host "QUICK TEST MODE - Reduced parameters" -ForegroundColor Yellow
}

# ============================================================
# HELPER FUNCTIONS
# ============================================================

function Stop-AllNodes {
    Get-Process -Name "koorde-node" -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 2
}

function Start-Cluster {
    param([int]$NodeCount, [string]$ConfigDir)
    
    Start-Process -FilePath ".\bin\koorde-node.exe" `
        -ArgumentList "-config", "$ConfigDir/node0.yaml" `
        -RedirectStandardOutput "logs/bench-node0.log" `
        -RedirectStandardError "logs/bench-node0.err" `
        -WindowStyle Hidden
    
    Start-Sleep -Seconds 3
    
    for ($i = 1; $i -lt $NodeCount; $i++) {
        Start-Process -FilePath ".\bin\koorde-node.exe" `
            -ArgumentList "-config", "$ConfigDir/node$i.yaml" `
            -RedirectStandardOutput "logs/bench-node$i.log" `
            -RedirectStandardError "logs/bench-node$i.err" `
            -WindowStyle Hidden
        
        $delay = if ($NodeCount -gt 16) { 400 } else { 300 }
        Start-Sleep -Milliseconds $delay
    }
}

function Wait-ForClusterReady {
    param([int]$NodeCount, [int]$TimeoutSec = 90)
    
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        $ready = 0
        for ($i = 0; $i -lt $NodeCount; $i++) {
            try {
                $health = Invoke-RestMethod "http://localhost:$(8080+$i)/health" -TimeoutSec 2
                if ($health.status -eq "READY") { $ready++ }
            } catch {}
        }
        if ($ready -eq $NodeCount) { return $true }
        Start-Sleep -Seconds 2
    }
    return $false
}

# Wait for de Bruijn routing tables to be populated (Koorde only)
function Wait-ForDeBruijnReady {
    param(
        [int]$NodeCount, 
        [int]$ExpectedDegree,
        [int]$TimeoutSec = 120,
        [int]$MinNodesWithDB = -1  # -1 means all nodes
    )
    
    if ($MinNodesWithDB -lt 0) {
        # Require at least 80% of nodes to have de Bruijn entries
        $MinNodesWithDB = [Math]::Ceiling($NodeCount * 0.8)
    }
    
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $lastCount = 0
    
    while ((Get-Date) -lt $deadline) {
        $nodesWithDB = 0
        $totalEntries = 0
        
        for ($i = 0; $i -lt $NodeCount; $i++) {
            try {
                $health = Invoke-RestMethod "http://localhost:$(8080+$i)/health" -TimeoutSec 2
                # de_bruijn_count is nested inside details object
                $dbCount = [int]$health.details.de_bruijn_count
                if ($dbCount -gt 0) {
                    $nodesWithDB++
                    $totalEntries += $dbCount
                }
            } catch {}
        }
        
        $avgEntries = if ($nodesWithDB -gt 0) { [Math]::Round($totalEntries / $nodesWithDB, 1) } else { 0 }
        
        # Show progress if count changed
        if ($nodesWithDB -ne $lastCount) {
            Write-Host "    De Bruijn progress: $nodesWithDB/$NodeCount nodes have entries (avg: $avgEntries)" -ForegroundColor Gray
            $lastCount = $nodesWithDB
        }
        
        # Check if enough nodes have de Bruijn entries
        if ($nodesWithDB -ge $MinNodesWithDB -and $avgEntries -ge ($ExpectedDegree * 0.5)) {
            Write-Host "    De Bruijn tables ready: $nodesWithDB nodes, avg $avgEntries entries" -ForegroundColor Green
            return $true
        }
        
        Start-Sleep -Seconds 3
    }
    
    Write-Host "    WARNING: De Bruijn tables not fully populated (got $lastCount/$MinNodesWithDB nodes)" -ForegroundColor Yellow
    return $false
}

function Get-ClusterStats {
    param([int]$NodeCount)
    
    $totalDB = 0
    $totalSucc = 0
    $totalEntries = 0
    $protocol = "unknown"
    
    for ($i = 0; $i -lt $NodeCount; $i++) {
        try {
            $metrics = Invoke-RestMethod "http://localhost:$(8080+$i)/metrics" -TimeoutSec 2
            $protocol = $metrics.routing.stats.protocol
            $totalDB += [int]$metrics.routing.stats.de_bruijn_success
            $totalSucc += [int]$metrics.routing.stats.successor_fallbacks
            $totalEntries += [int]$metrics.routing.debruijn_count
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

function Run-Workload {
    param(
        [int]$NodeCount, 
        [int]$Reqs, 
        [int]$ReqRate, 
        [string]$OutputFile,
        [switch]$IsWarmup
    )
    
    $targets = @()
    for ($i = 0; $i -lt $NodeCount; $i++) {
        $targets += "http://localhost:$(8080+$i)"
    }
    $targetsStr = $targets -join ','
    
    & ./bin/cache-workload.exe -targets $targetsStr -requests $Reqs -rate $ReqRate -urls 500 -output $OutputFile 2>&1 | Out-Null
    
    if (-not (Test-Path $OutputFile)) {
        return $null
    }
    
    $csv = Import-Csv $OutputFile
    $latencies = $csv | ForEach-Object { [double]$_.latency_ms }
    $successes = ($csv | Where-Object { $_.status -eq "200" }).Count
    
    if ($latencies.Count -eq 0) { return $null }
    
    $sorted = $latencies | Sort-Object
    $count = $sorted.Count
    
    return @{
        AvgLatency = [Math]::Round(($latencies | Measure-Object -Average).Average, 2)
        MinLatency = [Math]::Round(($latencies | Measure-Object -Minimum).Minimum, 2)
        MaxLatency = [Math]::Round(($latencies | Measure-Object -Maximum).Maximum, 2)
        P50 = [Math]::Round($sorted[[Math]::Floor($count * 0.50)], 2)
        P75 = [Math]::Round($sorted[[Math]::Floor($count * 0.75)], 2)
        P90 = [Math]::Round($sorted[[Math]::Floor($count * 0.90)], 2)
        P95 = [Math]::Round($sorted[[Math]::Floor($count * 0.95)], 2)
        P99 = [Math]::Round($sorted[[Math]::Floor($count * 0.99)], 2)
        SuccessRate = [Math]::Round($successes / $Reqs * 100, 2)
        TotalRequests = $count
        Successes = $successes
    }
}

function Run-SingleTest {
    param(
        [string]$Protocol,
        [int]$Nodes,
        [int]$Degree,
        [string]$TestId
    )
    
    $configDir = if ($Protocol -eq "chord") { "config/chord-cluster" } else { "config/test-cluster" }
    
    Stop-AllNodes
    
    if ($Protocol -eq "chord") {
        & ./scripts/generate-chord-configs.ps1 -Nodes $Nodes -OutputDir $configDir -SimulatedLatencyMs $script:SimulatedLatencyMs 2>&1 | Out-Null
    } else {
        & ./scripts/generate-cluster-configs.ps1 -Nodes $Nodes -Degree $Degree -OutputDir $configDir -SimulatedLatencyMs $script:SimulatedLatencyMs 2>&1 | Out-Null
    }
    
    # Dynamic stabilization based on cluster size
    $dynamicStabilization = [Math]::Max($script:StabilizationTime, $Nodes * 2)
    Write-Host "    Starting $Nodes-node cluster (stabilization: ${dynamicStabilization}s)..." -ForegroundColor Gray
    
    Start-Cluster -NodeCount $Nodes -ConfigDir $configDir
    Start-Sleep -Seconds $dynamicStabilization
    
    $ready = Wait-ForClusterReady -NodeCount $Nodes -TimeoutSec 60
    if (-not $ready) {
        Write-Host "    FAILED: Cluster not ready" -ForegroundColor Red
        Stop-AllNodes
        return $null
    }
    
    # For Koorde: wait for de Bruijn tables to be populated
    if ($Protocol -eq "koorde") {
        Write-Host "    Waiting for de Bruijn tables..." -ForegroundColor Gray
        $dbReady = Wait-ForDeBruijnReady -NodeCount $Nodes -ExpectedDegree $Degree -TimeoutSec 90
        if (-not $dbReady) {
            Write-Host "    WARNING: Proceeding with incomplete de Bruijn tables" -ForegroundColor Yellow
        }
        # Additional stabilization after de Bruijn population
        Start-Sleep -Seconds 5
    }
    
    if ($script:WarmupRequests -gt 0) {
        Run-Workload -NodeCount $Nodes -Reqs $script:WarmupRequests -ReqRate $script:Rate `
            -OutputFile "$script:OutputDir/warmup-$TestId.csv" -IsWarmup | Out-Null
        Start-Sleep -Seconds 2
    }
    
    $result = Run-Workload -NodeCount $Nodes -Reqs $script:Requests -ReqRate $script:Rate `
        -OutputFile "$script:OutputDir/raw-$TestId.csv"
    
    $stats = Get-ClusterStats -NodeCount $Nodes
    
    Stop-AllNodes
    
    if ($result -eq $null) {
        return $null
    }
    
    return @{
        Protocol = $Protocol
        Nodes = $Nodes
        Degree = $Degree
        AvgLatency = $result.AvgLatency
        MinLatency = $result.MinLatency
        MaxLatency = $result.MaxLatency
        P50 = $result.P50
        P75 = $result.P75
        P90 = $result.P90
        P95 = $result.P95
        P99 = $result.P99
        SuccessRate = $result.SuccessRate
        DeBruijnUsage = $stats.DeBruijnUsage
        DeBruijnSuccess = $stats.DeBruijnSuccess
        SuccessorFallback = $stats.SuccessorFallback
        AvgDBEntries = $stats.AvgEntries
    }
}

# ============================================================
# MAIN SCRIPT
# ============================================================

$startTime = Get-Date
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "     COMPREHENSIVE CHORD vs KOORDE BENCHMARK SUITE" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Configuration:" -ForegroundColor Yellow
Write-Host "  Node Counts:  $($NodeCounts -join ', ')"
Write-Host "  Degrees:      $($Degrees -join ', ') - Koorde only"
Write-Host "  Protocols:    $($Protocols -join ', ')"
Write-Host "  Requests:     $Requests per test"
Write-Host "  Warmup:       $WarmupRequests requests"
Write-Host "  Rate:         $Rate req/s"
if ($SimulatedLatencyMs -gt 0) {
    Write-Host "  Sim Latency:  ${SimulatedLatencyMs}ms per hop" -ForegroundColor Yellow
} else {
    Write-Host "  Sim Latency:  disabled (real network)"
}
Write-Host ""

$runChord = $Protocols -contains "chord"
$runKoorde = $Protocols -contains "koorde"

$totalChordTests = if ($runChord) { $NodeCounts.Count } else { 0 }
$totalKoordeTests = if ($runKoorde) { $NodeCounts.Count * $Degrees.Count } else { 0 }
$totalTests = $totalChordTests + $totalKoordeTests
$testSummary = "Total Tests: $totalTests"
if ($runChord) { $testSummary += " - $totalChordTests Chord" }
if ($runKoorde) { $testSummary += " - $totalKoordeTests Koorde" }
Write-Host $testSummary -ForegroundColor Yellow
Write-Host ""

if (-not $SkipBuild) {
    Write-Host "BUILD: Compiling binaries..." -ForegroundColor Gray
    go build -o bin/koorde-node.exe ./cmd/node 2>&1 | Out-Null
    go build -o bin/cache-workload.exe ./cmd/cache-workload 2>&1 | Out-Null
    Write-Host "  Done." -ForegroundColor Green
    Write-Host ""
}

New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
New-Item -ItemType Directory -Path "logs" -Force | Out-Null

Write-Host "CLEANUP: Stopping any existing nodes..." -ForegroundColor Gray
Stop-AllNodes
Write-Host ""

$allResults = @()
$testNum = 0

# ============================================================
# RUN CHORD TESTS
# ============================================================
if ($runChord) {
    Write-Host "==============================================================" -ForegroundColor Blue
    Write-Host "  PHASE 1: CHORD TESTS" -ForegroundColor Blue
    Write-Host "==============================================================" -ForegroundColor Blue
    Write-Host ""

    foreach ($nodes in $NodeCounts) {
        $testNum++
        $testId = "chord-n$nodes"
        $theoreticalHops = [Math]::Ceiling([Math]::Log($nodes) / [Math]::Log(2))
        
        Write-Host "Test $testNum of $totalTests - Chord: $nodes nodes - approx $theoreticalHops hops" -ForegroundColor Yellow
        
        $result = Run-SingleTest -Protocol "chord" -Nodes $nodes -Degree 0 -TestId $testId
        
        if ($result) {
            $allResults += $result
            Write-Host "    Avg: $($result.AvgLatency)ms - P95: $($result.P95)ms - Success: $($result.SuccessRate) pct" -ForegroundColor Green
        } else {
            Write-Host "    FAILED" -ForegroundColor Red
        }
        Write-Host ""
    }
}

# ============================================================
# RUN KOORDE TESTS
# ============================================================
if ($runKoorde) {
    Write-Host "==============================================================" -ForegroundColor Magenta
    Write-Host "  PHASE 2: KOORDE TESTS" -ForegroundColor Magenta
    Write-Host "==============================================================" -ForegroundColor Magenta
    Write-Host ""

    foreach ($nodes in $NodeCounts) {
        foreach ($degree in $Degrees) {
            $testNum++
            $testId = "koorde-n$nodes-d$degree"
            $m = [Math]::Ceiling([Math]::Log($nodes) / [Math]::Log(2))
            $logD = [Math]::Max(1, [Math]::Log($degree) / [Math]::Log(2))
            $theoreticalHops = [Math]::Ceiling($m / $logD)
            
            Write-Host "Test $testNum of $totalTests - Koorde: $nodes nodes, degree $degree - approx $theoreticalHops hops" -ForegroundColor Yellow
            
            $result = Run-SingleTest -Protocol "koorde" -Nodes $nodes -Degree $degree -TestId $testId
            
            if ($result) {
                $allResults += $result
                Write-Host "    Avg: $($result.AvgLatency)ms - P95: $($result.P95)ms - Success: $($result.SuccessRate) pct - DB: $($result.DeBruijnUsage) pct" -ForegroundColor Green
            } else {
                Write-Host "    FAILED" -ForegroundColor Red
            }
            Write-Host ""
        }
    }
}

# ============================================================
# GENERATE REPORTS
# ============================================================
Write-Host "==============================================================" -ForegroundColor Cyan
Write-Host "  GENERATING REPORTS" -ForegroundColor Cyan
Write-Host "==============================================================" -ForegroundColor Cyan
Write-Host ""

$csvFile = "$OutputDir/benchmark-results-$timestamp.csv"
# Convert hashtables to PSCustomObjects for proper CSV export
$csvResults = $allResults | ForEach-Object {
    [PSCustomObject]@{
        Protocol = $_.Protocol
        Nodes = $_.Nodes
        Degree = $_.Degree
        AvgLatency = $_.AvgLatency
        MinLatency = $_.MinLatency
        MaxLatency = $_.MaxLatency
        P50 = $_.P50
        P75 = $_.P75
        P90 = $_.P90
        P95 = $_.P95
        P99 = $_.P99
        SuccessRate = $_.SuccessRate
        DeBruijnUsage = $_.DeBruijnUsage
        DeBruijnSuccess = $_.DeBruijnSuccess
        SuccessorFallback = $_.SuccessorFallback
        AvgDBEntries = $_.AvgDBEntries
    }
}
$csvResults | Export-Csv -Path $csvFile -NoTypeInformation
Write-Host "Raw CSV: $csvFile" -ForegroundColor Gray

$reportFile = "$OutputDir/benchmark-report-$timestamp.md"

# Build report as array of lines to avoid here-string issues
$reportLines = @()
$reportLines += "# Comprehensive Chord vs Koorde Benchmark Report"
$reportLines += ""
$reportLines += "**Generated:** $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
$durationMins = [Math]::Round(((Get-Date) - $startTime).TotalMinutes, 1)
$reportLines += "**Test Duration:** $durationMins minutes"
$reportLines += ""
$reportLines += "## Test Configuration"
$reportLines += ""
$reportLines += "| Parameter | Value |"
$reportLines += "|-----------|-------|"
$reportLines += "| Node Counts | $($NodeCounts -join ', ') |"
$reportLines += "| Koorde Degrees | $($Degrees -join ', ') |"
$reportLines += "| Requests per Test | $Requests |"
$reportLines += "| Warmup Requests | $WarmupRequests |"
$reportLines += "| Request Rate | $Rate req/s |"
$reportLines += ""

# Average Latency Matrix
$reportLines += "## Summary Matrix"
$reportLines += ""
$reportLines += "### Average Latency (ms) - Lower is Better"
$reportLines += ""
$header = "| Nodes | Chord |"
$separator = "|-------|-------|"
foreach ($d in $Degrees) {
    $header += " Koorde d=$d |"
    $separator += "------------|"
}
$reportLines += $header
$reportLines += $separator

foreach ($nodes in $NodeCounts) {
    $chordResult = $allResults | Where-Object { $_.Protocol -eq "chord" -and $_.Nodes -eq $nodes }
    $chordLatency = if ($chordResult) { "$($chordResult.AvgLatency)" } else { "N/A" }
    
    $row = "| $nodes | $chordLatency |"
    foreach ($degree in $Degrees) {
        $koordeResult = $allResults | Where-Object { $_.Protocol -eq "koorde" -and $_.Nodes -eq $nodes -and $_.Degree -eq $degree }
        $koordeLatency = if ($koordeResult) { "$($koordeResult.AvgLatency)" } else { "N/A" }
        $row += " $koordeLatency |"
    }
    $reportLines += $row
}
$reportLines += ""

# P95 Latency Matrix
$reportLines += "### P95 Latency (ms) - Lower is Better"
$reportLines += ""
$reportLines += $header
$reportLines += $separator

foreach ($nodes in $NodeCounts) {
    $chordResult = $allResults | Where-Object { $_.Protocol -eq "chord" -and $_.Nodes -eq $nodes }
    $chordP95 = if ($chordResult) { "$($chordResult.P95)" } else { "N/A" }
    
    $row = "| $nodes | $chordP95 |"
    foreach ($degree in $Degrees) {
        $koordeResult = $allResults | Where-Object { $_.Protocol -eq "koorde" -and $_.Nodes -eq $nodes -and $_.Degree -eq $degree }
        $koordeP95 = if ($koordeResult) { "$($koordeResult.P95)" } else { "N/A" }
        $row += " $koordeP95 |"
    }
    $reportLines += $row
}
$reportLines += ""

# Success Rate Matrix
$reportLines += "### Success Rate (%) - Higher is Better"
$reportLines += ""
$reportLines += $header
$reportLines += $separator

foreach ($nodes in $NodeCounts) {
    $chordResult = $allResults | Where-Object { $_.Protocol -eq "chord" -and $_.Nodes -eq $nodes }
    $chordSuccess = if ($chordResult) { "$($chordResult.SuccessRate)%" } else { "N/A" }
    
    $row = "| $nodes | $chordSuccess |"
    foreach ($degree in $Degrees) {
        $koordeResult = $allResults | Where-Object { $_.Protocol -eq "koorde" -and $_.Nodes -eq $nodes -and $_.Degree -eq $degree }
        $koordeSuccess = if ($koordeResult) { "$($koordeResult.SuccessRate)%" } else { "N/A" }
        $row += " $koordeSuccess |"
    }
    $reportLines += $row
}
$reportLines += ""

# De Bruijn Usage Matrix
$reportLines += "### De Bruijn Routing Usage (%) - Koorde Only"
$reportLines += ""
$dbHeader = "| Nodes |"
$dbSeparator = "|-------|"
foreach ($d in $Degrees) {
    $dbHeader += " Degree $d |"
    $dbSeparator += "----------|"
}
$reportLines += $dbHeader
$reportLines += $dbSeparator

foreach ($nodes in $NodeCounts) {
    $row = "| $nodes |"
    foreach ($degree in $Degrees) {
        $koordeResult = $allResults | Where-Object { $_.Protocol -eq "koorde" -and $_.Nodes -eq $nodes -and $_.Degree -eq $degree }
        $dbUsage = if ($koordeResult) { "$($koordeResult.DeBruijnUsage)%" } else { "N/A" }
        $row += " $dbUsage |"
    }
    $reportLines += $row
}
$reportLines += ""

# Detailed Results
$reportLines += "## Detailed Results"
$reportLines += ""
$reportLines += "| Protocol | Nodes | Degree | Avg ms | P50 ms | P95 ms | P99 ms | Success | DB Usage |"
$reportLines += "|----------|-------|--------|--------|--------|--------|--------|---------|----------|"

foreach ($r in $allResults) {
    $degreeStr = if ($r.Protocol -eq "chord") { "-" } else { "$($r.Degree)" }
    $dbUsageStr = if ($r.Protocol -eq "chord") { "N/A" } else { "$($r.DeBruijnUsage)%" }
    $reportLines += "| $($r.Protocol) | $($r.Nodes) | $degreeStr | $($r.AvgLatency) | $($r.P50) | $($r.P95) | $($r.P99) | $($r.SuccessRate)% | $dbUsageStr |"
}
$reportLines += ""

# Performance Comparison
$reportLines += "## Performance Comparison"
$reportLines += ""
$reportLines += "### Koorde vs Chord Improvement (Positive = Koorde Faster)"
$reportLines += ""
$reportLines += $dbHeader
$reportLines += $dbSeparator

foreach ($nodes in $NodeCounts) {
    $chordResult = $allResults | Where-Object { $_.Protocol -eq "chord" -and $_.Nodes -eq $nodes }
    $row = "| $nodes |"
    
    foreach ($degree in $Degrees) {
        $koordeResult = $allResults | Where-Object { $_.Protocol -eq "koorde" -and $_.Nodes -eq $nodes -and $_.Degree -eq $degree }
        
        if ($chordResult -and $koordeResult -and $chordResult.AvgLatency -gt 0) {
            $improvement = [Math]::Round(($chordResult.AvgLatency - $koordeResult.AvgLatency) / $chordResult.AvgLatency * 100, 1)
            $sign = if ($improvement -ge 0) { "+" } else { "" }
            $row += " $sign$improvement% |"
        } else {
            $row += " N/A |"
        }
    }
    $reportLines += $row
}
$reportLines += ""

# Theoretical Hops
$reportLines += "## Theoretical Analysis"
$reportLines += ""
$reportLines += "### Expected Hop Counts"
$reportLines += ""
$hopHeader = "| Nodes | Chord O(log n) |"
$hopSeparator = "|-------|----------------|"
foreach ($d in $Degrees) {
    $hopHeader += " Koorde d=$d |"
    $hopSeparator += "------------|"
}
$reportLines += $hopHeader
$reportLines += $hopSeparator

foreach ($nodes in $NodeCounts) {
    $m = [Math]::Ceiling([Math]::Log($nodes) / [Math]::Log(2))
    $row = "| $nodes | ~$m hops |"
    
    foreach ($degree in $Degrees) {
        $logD = [Math]::Max(1, [Math]::Log($degree) / [Math]::Log(2))
        $koordeHops = [Math]::Ceiling($m / $logD)
        $row += " ~$koordeHops hops |"
    }
    $reportLines += $row
}
$reportLines += ""

# Key Findings
$reportLines += "## Key Findings"
$reportLines += ""

$koordeResults = $allResults | Where-Object { $_.Protocol -eq "koorde" }
if ($koordeResults.Count -gt 0) {
    $bestKoorde = $koordeResults | Sort-Object AvgLatency | Select-Object -First 1
    $worstKoorde = $koordeResults | Sort-Object AvgLatency | Select-Object -Last 1
    
    $reportLines += "1. **Best Koorde Configuration:** $($bestKoorde.Nodes) nodes, degree $($bestKoorde.Degree) - Avg: $($bestKoorde.AvgLatency)ms"
    $reportLines += "2. **Worst Koorde Configuration:** $($worstKoorde.Nodes) nodes, degree $($worstKoorde.Degree) - Avg: $($worstKoorde.AvgLatency)ms"
    $reportLines += ""
}

# Find configurations where Koorde wins
$reportLines += "### Configurations Where Koorde Outperforms Chord"
$reportLines += ""
$koordeWins = @()
foreach ($nodes in $NodeCounts) {
    $chordResult = $allResults | Where-Object { $_.Protocol -eq "chord" -and $_.Nodes -eq $nodes }
    foreach ($degree in $Degrees) {
        $koordeResult = $allResults | Where-Object { $_.Protocol -eq "koorde" -and $_.Nodes -eq $nodes -and $_.Degree -eq $degree }
        if ($chordResult -and $koordeResult -and $koordeResult.AvgLatency -lt $chordResult.AvgLatency) {
            $improvement = [Math]::Round(($chordResult.AvgLatency - $koordeResult.AvgLatency) / $chordResult.AvgLatency * 100, 1)
            $koordeWins += "- **$nodes nodes, degree $degree**: Koorde is $improvement% faster"
        }
    }
}

if ($koordeWins.Count -gt 0) {
    foreach ($win in $koordeWins) {
        $reportLines += $win
    }
} else {
    $reportLines += "Chord outperformed Koorde in all tested configurations."
    $reportLines += ""
    $reportLines += "This may indicate:"
    $reportLines += "- Cluster sizes too small for Koorde's hop reduction to offset computational overhead"
    $reportLines += "- Need higher degrees for better de Bruijn routing coverage"
    $reportLines += "- Local testing environment favors simpler routing logic"
}
$reportLines += ""
$reportLines += "---"
$reportLines += "*Report generated by comprehensive-benchmark.ps1*"

# Write report
$reportLines -join "`n" | Out-File -FilePath $reportFile -Encoding UTF8
Write-Host "Report: $reportFile" -ForegroundColor Gray

# ============================================================
# PRINT SUMMARY
# ============================================================
Write-Host ""
Write-Host "================================================================" -ForegroundColor Green
Write-Host "                    BENCHMARK COMPLETE" -ForegroundColor Green
Write-Host "================================================================" -ForegroundColor Green
Write-Host ""
$durationFinal = [Math]::Round(((Get-Date) - $startTime).TotalMinutes, 1)
Write-Host "Duration: $durationFinal minutes" -ForegroundColor Gray
Write-Host "Results:  $OutputDir" -ForegroundColor Gray
Write-Host ""

# Print quick summary table
Write-Host "QUICK SUMMARY - Average Latency (ms):" -ForegroundColor Yellow
Write-Host "-------------------------------------------------------------" -ForegroundColor Gray

$headerLine = "Nodes".PadRight(8) + "Chord".PadRight(12)
foreach ($d in $Degrees) { $headerLine += "Koorde d=$d".PadRight(14) }
Write-Host $headerLine -ForegroundColor Cyan

Write-Host "-------------------------------------------------------------" -ForegroundColor Gray

foreach ($nodes in $NodeCounts) {
    $chordResult = $allResults | Where-Object { $_.Protocol -eq "chord" -and $_.Nodes -eq $nodes }
    $chordVal = if ($chordResult) { "$($chordResult.AvgLatency)" } else { "N/A" }
    
    $line = "$nodes".PadRight(8) + $chordVal.PadRight(12)
    
    foreach ($degree in $Degrees) {
        $koordeResult = $allResults | Where-Object { $_.Protocol -eq "koorde" -and $_.Nodes -eq $nodes -and $_.Degree -eq $degree }
        $koordeVal = if ($koordeResult) { "$($koordeResult.AvgLatency)" } else { "N/A" }
        $line += $koordeVal.PadRight(14)
    }
    
    Write-Host $line
}

Write-Host ""
Write-Host "Full report: $reportFile" -ForegroundColor Cyan
Write-Host ""
