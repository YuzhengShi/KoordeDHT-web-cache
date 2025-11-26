# Benchmark Script: Chord vs Koorde Web Cache Performance
# This script compares the performance of Chord and Koorde DHT protocols
# for web caching workloads

param(
    [int]$NumNodes = 5,
    [int]$NumRequests = 1000,
    [int]$Concurrency = 10,
    [double]$ZipfExponent = 1.2,
    [int]$WarmupSeconds = 30,
    [int]$TestDurationSeconds = 60
)

$ErrorActionPreference = "Stop"

Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Chord vs Koorde Web Cache Benchmark" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Configuration:" -ForegroundColor Yellow
Write-Host "  Nodes: $NumNodes" -ForegroundColor Gray
Write-Host "  Requests: $NumRequests" -ForegroundColor Gray
Write-Host "  Concurrency: $Concurrency" -ForegroundColor Gray
Write-Host "  Zipf Exponent: $ZipfExponent" -ForegroundColor Gray
Write-Host "  Warmup: $WarmupSeconds seconds" -ForegroundColor Gray
Write-Host "  Test Duration: $TestDurationSeconds seconds" -ForegroundColor Gray
Write-Host ""

# Build binaries if needed
if (-not (Test-Path "bin/node.exe")) {
    Write-Host "Building node binary..." -ForegroundColor Yellow
    go build -o bin/node.exe ./cmd/node
}

if (-not (Test-Path "bin/cache-workload.exe")) {
    Write-Host "Building cache-workload binary..." -ForegroundColor Yellow
    go build -o bin/cache-workload.exe ./cmd/cache-workload
}

# Create directories
New-Item -ItemType Directory -Force -Path "benchmark" | Out-Null
New-Item -ItemType Directory -Force -Path "benchmark/chord" | Out-Null
New-Item -ItemType Directory -Force -Path "benchmark/koorde" | Out-Null
New-Item -ItemType Directory -Force -Path "benchmark/results" | Out-Null
New-Item -ItemType Directory -Force -Path "logs" | Out-Null

# Clean up old results
Remove-Item -Path "benchmark/chord/*" -ErrorAction SilentlyContinue
Remove-Item -Path "benchmark/koorde/*" -ErrorAction SilentlyContinue

# Number of unique URLs for workload (workload generator will create httpbin.org URLs)
$numTestUrls = 10

# Function to generate config for a node
function Generate-NodeConfig {
    param(
        [int]$NodeIndex,
        [string]$Protocol,
        [int]$BaseGrpcPort,
        [int]$BaseHttpPort,
        [string[]]$BootstrapPeers
    )
    
    $grpcPort = $BaseGrpcPort + $NodeIndex
    $httpPort = $BaseHttpPort + $NodeIndex
    
    $bootstrapPeersStr = if ($BootstrapPeers.Count -eq 0) { "[]" } else { "[`"$($BootstrapPeers -join '","')`"]" }
    
    @"
logger:
  active: true
  level: info
  encoding: console
  mode: stdout

dht:
  idBits: 66
  protocol: $Protocol
  mode: private
  bootstrap:
    mode: static
    peers: $bootstrapPeersStr
  deBruijn:
    degree: 8
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
  port: $grpcPort

cache:
  enabled: true
  httpPort: $httpPort
  capacityMB: 1024
  defaultTTL: 3600
  hotspotThreshold: 50.0
  hotspotDecayRate: 0.65

telemetry:
  tracing:
    enabled: false
"@
}

# Function to start a cluster
function Start-Cluster {
    param(
        [string]$Protocol,
        [int]$BaseGrpcPort,
        [int]$BaseHttpPort
    )
    
    Write-Host "Starting $Protocol cluster..." -ForegroundColor Green
    
    $jobs = @()
    $scriptDir = Get-Location
    
    for ($i = 0; $i -lt $NumNodes; $i++) {
        $bootstrapPeers = if ($i -eq 0) { @() } else { @("localhost:$BaseGrpcPort") }
        $config = Generate-NodeConfig -NodeIndex $i -Protocol $Protocol -BaseGrpcPort $BaseGrpcPort -BaseHttpPort $BaseHttpPort -BootstrapPeers $bootstrapPeers
        $configPath = "benchmark/$Protocol/node$i.yaml"
        $config | Out-File -FilePath $configPath -Encoding utf8
        
        $logFile = "bench-$Protocol-node$i.log"
        $logPath = Join-Path (Join-Path $scriptDir "logs") $logFile
        $configFullPath = Join-Path $scriptDir $configPath
        $nodeExePath = Join-Path $scriptDir "bin/node.exe"
        
        $job = Start-Job -ScriptBlock {
            param($nodeExe, $config, $logPath)
            # Ensure log directory exists
            $logDir = Split-Path $logPath -Parent
            New-Item -ItemType Directory -Force -Path $logDir | Out-Null
            # Start node and redirect output
            & $nodeExe -config $config *> $logPath 2>&1
        } -ArgumentList $nodeExePath, $configFullPath, $logPath
        
        $jobs += $job
        Write-Host "  Started node $i (Job ID: $($job.Id), Port: $($BaseHttpPort + $i))" -ForegroundColor Gray
        
        if ($i -lt ($NumNodes - 1)) {
            Start-Sleep -Seconds 2
        }
    }
    
    Write-Host "  Waiting $WarmupSeconds seconds for cluster stabilization..." -ForegroundColor Yellow
    Start-Sleep -Seconds $WarmupSeconds
    
    # Verify nodes are ready
    Write-Host "  Verifying nodes are ready..." -ForegroundColor Yellow
    $readyNodes = 0
    for ($i = 0; $i -lt $NumNodes; $i++) {
        $port = $BaseHttpPort + $i
        $maxRetries = 10
        $retryCount = 0
        $isReady = $false
        
        while ($retryCount -lt $maxRetries -and -not $isReady) {
            try {
                $response = Invoke-WebRequest -Uri "http://localhost:$port/health" -TimeoutSec 2 -UseBasicParsing -ErrorAction Stop
                if ($response.Content -match '"healthy":\s*true') {
                    $isReady = $true
                    $readyNodes++
                    Write-Host "    Node $i (port $port): Ready" -ForegroundColor Green
                }
            } catch {
                $retryCount++
                if ($retryCount -lt $maxRetries) {
                    Start-Sleep -Seconds 1
                }
            }
        }
        
        if (-not $isReady) {
            Write-Host "    Node $i (port $port): Not ready after $maxRetries attempts" -ForegroundColor Yellow
        }
    }
    
    Write-Host "  $readyNodes/$NumNodes nodes ready" -ForegroundColor $(if ($readyNodes -eq $NumNodes) { "Green" } else { "Yellow" })
    
    return $jobs
}

# Function to stop a cluster
function Stop-Cluster {
    param([System.Management.Automation.Job[]]$Jobs)
    
    Write-Host "Stopping cluster..." -ForegroundColor Yellow
    Stop-Job -Job $Jobs -ErrorAction SilentlyContinue
    Remove-Job -Job $Jobs -ErrorAction SilentlyContinue
}

# Function to run benchmark
function Run-Benchmark {
    param(
        [string]$Protocol,
        [int]$HttpPort,
        [string]$OutputFile
    )
    
    Write-Host "Running $Protocol benchmark..." -ForegroundColor Green
    $targetUrls = @()
    for ($i = 0; $i -lt $NumNodes; $i++) {
        $targetUrls += "http://localhost:$($HttpPort + $i)"
    }
    $targetsArg = $targetUrls -join ","
    Write-Host "  Targets: $targetsArg" -ForegroundColor Gray
    Write-Host "  Output: $OutputFile" -ForegroundColor Gray
    
    # Run workload
    $process = Start-Process -FilePath "bin/cache-workload.exe" -ArgumentList @(
        "--targets", $targetsArg,
        "--urls", $numTestUrls,
        "--requests", $NumRequests,
        "--rate", $Concurrency,
        "--zipf", $ZipfExponent,
        "--output", $OutputFile
    ) -Wait -PassThru -NoNewWindow -RedirectStandardOutput "benchmark/results/$Protocol-workload.log" -RedirectStandardError "benchmark/results/$Protocol-workload-error.log"
    
    if ($process.ExitCode -ne 0) {
        Write-Host "  ⚠ Workload generator exited with code $($process.ExitCode)" -ForegroundColor Yellow
    }
    
    return $OutputFile
}

# Function to collect metrics
function Collect-Metrics {
    param(
        [string]$Protocol,
        [int]$BaseHttpPort
    )
    
    $metrics = @{
        Protocol = $Protocol
        Nodes = @()
        CacheMetrics = @{}
        RoutingMetrics = @{}
    }

    $routingSuccessLatencySum = 0.0
    $routingFailureLatencySum = 0.0
    $routingFallbackLatencySum = 0.0
    
    for ($i = 0; $i -lt $NumNodes; $i++) {
        $port = $BaseHttpPort + $i
        try {
            # Add retry logic for metrics collection
            $maxRetries = 3
            $retryCount = 0
            $response = $null
            
            while ($retryCount -lt $maxRetries) {
                try {
                    $response = Invoke-WebRequest -Uri "http://localhost:$port/metrics" -TimeoutSec 10 -UseBasicParsing -ErrorAction Stop
                    break
                } catch {
                    $retryCount++
                    if ($retryCount -lt $maxRetries) {
                        Start-Sleep -Seconds 2
                    } else {
                        throw
                    }
                }
            }
            
            $json = $response.Content | ConvertFrom-Json
            
            $nodeMetrics = @{
                NodeId = $json.node.id
                Address = $json.node.addr
                Port = $port
                Cache = @{
                    Hits = $json.cache.hits
                    Misses = $json.cache.misses
                    HitRate = $json.cache.hit_rate
                    Entries = $json.cache.entry_count
                    SizeBytes = $json.cache.size_bytes
                    CapacityBytes = $json.cache.capacity_bytes
                    Utilization = $json.cache.utilization
                }
                Routing = @{
                    SuccessorCount = $json.routing.successor_count
                    DeBruijnCount = $json.routing.debruijn_count
                    HasPredecessor = $json.routing.has_predecessor
                }
                Hotspots = @{
                    Count = $json.hotspots.count
                }
            }
            
            $metrics.Nodes += $nodeMetrics
            
            # Aggregate cache metrics
            $metrics.CacheMetrics.Hits += $json.cache.hits
            $metrics.CacheMetrics.Misses += $json.cache.misses
            $metrics.CacheMetrics.Entries += $json.cache.entry_count
            $metrics.CacheMetrics.SizeBytes += $json.cache.size_bytes

            if ($json.routing.stats) {
                if (-not $metrics.RoutingMetrics.Protocol) {
                    $metrics.RoutingMetrics = @{
                        Protocol = $json.routing.stats.protocol
                        DeBruijnSuccess = 0
                        DeBruijnFailures = 0
                        SuccessorFallbacks = 0
                        AvgDeBruijnSuccessMs = 0
                        AvgDeBruijnFailureMs = 0
                        AvgSuccessorFallbackMs = 0
                    }
                }

                $successCount = [double]$json.routing.stats.de_bruijn_success
                $failureCount = [double]$json.routing.stats.de_bruijn_failures
                $fallbackCount = [double]$json.routing.stats.successor_fallbacks

                $metrics.RoutingMetrics.DeBruijnSuccess += $successCount
                $metrics.RoutingMetrics.DeBruijnFailures += $failureCount
                $metrics.RoutingMetrics.SuccessorFallbacks += $fallbackCount

                $routingSuccessLatencySum += [double]$json.routing.stats.avg_de_bruijn_success_ms * $successCount
                $routingFailureLatencySum += [double]$json.routing.stats.avg_de_bruijn_failure_ms * $failureCount
                $routingFallbackLatencySum += [double]$json.routing.stats.avg_successor_fallback_ms * $fallbackCount
            }
            
        } catch {
            Write-Host "  ⚠ Failed to collect metrics from node $i (port $port): $_" -ForegroundColor Yellow
            # Add placeholder metrics to prevent errors
            $metrics.Nodes += @{
                NodeId = "unknown"
                Address = "localhost:$port"
                Port = $port
                Cache = @{
                    Hits = 0
                    Misses = 0
                    HitRate = 0
                    Entries = 0
                    SizeBytes = 0
                    CapacityBytes = 0
                    Utilization = 0
                }
                Routing = @{
                    SuccessorCount = 0
                    DeBruijnCount = 0
                    HasPredecessor = $false
                }
                Hotspots = @{
                    Count = 0
                }
            }
        }
    }
    
    # Initialize cache metrics if empty
    if (-not $metrics.CacheMetrics.Hits) { $metrics.CacheMetrics.Hits = 0 }
    if (-not $metrics.CacheMetrics.Misses) { $metrics.CacheMetrics.Misses = 0 }
    if (-not $metrics.CacheMetrics.Entries) { $metrics.CacheMetrics.Entries = 0 }
    if (-not $metrics.CacheMetrics.SizeBytes) { $metrics.CacheMetrics.SizeBytes = 0 }
    
    # Calculate aggregate hit rate
    $totalRequests = $metrics.CacheMetrics.Hits + $metrics.CacheMetrics.Misses
    if ($totalRequests -gt 0) {
        $metrics.CacheMetrics.HitRate = $metrics.CacheMetrics.Hits / $totalRequests
    } else {
        $metrics.CacheMetrics.HitRate = 0
    }

    if ($metrics.RoutingMetrics.Protocol) {
        if ($metrics.RoutingMetrics.DeBruijnSuccess -gt 0) {
            $metrics.RoutingMetrics.AvgDeBruijnSuccessMs = $routingSuccessLatencySum / $metrics.RoutingMetrics.DeBruijnSuccess
        }
        if ($metrics.RoutingMetrics.DeBruijnFailures -gt 0) {
            $metrics.RoutingMetrics.AvgDeBruijnFailureMs = $routingFailureLatencySum / $metrics.RoutingMetrics.DeBruijnFailures
        }
        if ($metrics.RoutingMetrics.SuccessorFallbacks -gt 0) {
            $metrics.RoutingMetrics.AvgSuccessorFallbackMs = $routingFallbackLatencySum / $metrics.RoutingMetrics.SuccessorFallbacks
        }
    }
    
    return $metrics
}

# Function to parse CSV results
function Parse-Results {
    param([string]$CsvFile)
    
    if (-not (Test-Path $CsvFile)) {
        return $null
    }
    
    $results = Import-Csv $CsvFile
    
    $stats = @{
        TotalRequests = $results.Count
        SuccessCount = ($results | Where-Object { $_.status -match '^[0-9]+$' -and ([int]$_.status -ge 200) -and ([int]$_.status -lt 300) }).Count
        ErrorCount = ($results | Where-Object { $_.status -match '^[0-9]+$' -and (([int]$_.status -lt 200) -or ([int]$_.status -ge 300)) }).Count
        Latencies = ($results | Where-Object { $_.latency_ms -ne "" } | ForEach-Object { [double]$_.latency_ms })
        CacheHits = ($results | Where-Object { $_.cache_status -like "*HIT*" }).Count
        CacheMisses = ($results | Where-Object { $_.cache_status -like "*MISS*" }).Count
    }
    
    if ($stats.Latencies.Count -gt 0) {
        $stats.AvgLatency = ($stats.Latencies | Measure-Object -Average).Average
        $stats.MinLatency = ($stats.Latencies | Measure-Object -Minimum).Minimum
        $stats.MaxLatency = ($stats.Latencies | Measure-Object -Maximum).Maximum
        $stats.P50Latency = ($stats.Latencies | Sort-Object)[[math]::Floor($stats.Latencies.Count * 0.50)]
        $stats.P95Latency = ($stats.Latencies | Sort-Object)[[math]::Floor($stats.Latencies.Count * 0.95)]
        $stats.P99Latency = ($stats.Latencies | Sort-Object)[[math]::Floor($stats.Latencies.Count * 0.99)]
    }
    
    if ($stats.TotalRequests -gt 0) {
        $stats.SuccessRate = $stats.SuccessCount / $stats.TotalRequests
        $stats.CacheHitRate = $stats.CacheHits / $stats.TotalRequests
    }
    
    return $stats
}

# Function to generate comparison report
function Generate-Report {
    param(
        [hashtable]$ChordResults,
        [hashtable]$KoordeResults,
        [hashtable]$ChordMetrics,
        [hashtable]$KoordeMetrics
    )
    
    $report = @"
============================================
  Chord vs Koorde Benchmark Results
============================================

Test Configuration:
  Nodes: $NumNodes
  Total Requests: $NumRequests
  Concurrency: $Concurrency
  Zipf Exponent: $ZipfExponent
  Warmup: $WarmupSeconds seconds

============================================
  Performance Metrics
============================================

Request Performance
═══════════════════════════════════════════════════════════════
Metric               | Chord            | Koorde
─────────────────────┼──────────────────┼───────────────────
Total Requests       │ $($ChordResults.TotalRequests.ToString().PadLeft(16)) │ $($KoordeResults.TotalRequests.ToString().PadLeft(17))
Success Rate         │ $("{0:P2}".PadLeft(16) -f $ChordResults.SuccessRate) │ $("{0:P2}".PadLeft(17) -f $KoordeResults.SuccessRate)
Error Rate           │ $("{0:P2}".PadLeft(16) -f (1-$ChordResults.SuccessRate)) │ $("{0:P2}".PadLeft(17) -f (1-$KoordeResults.SuccessRate))
─────────────────────┼──────────────────┼───────────────────
Avg Latency (ms)     │ $("{0:F2}".PadLeft(16) -f $ChordResults.AvgLatency) │ $("{0:F2}".PadLeft(17) -f $KoordeResults.AvgLatency)
Min Latency (ms)     │ $("{0:F2}".PadLeft(16) -f $ChordResults.MinLatency) │ $("{0:F2}".PadLeft(17) -f $KoordeResults.MinLatency)
Max Latency (ms)     │ $("{0:F2}".PadLeft(16) -f $ChordResults.MaxLatency) │ $("{0:F2}".PadLeft(17) -f $KoordeResults.MaxLatency)
P50 Latency (ms)     │ $("{0:F2}".PadLeft(16) -f $ChordResults.P50Latency) │ $("{0:F2}".PadLeft(17) -f $KoordeResults.P50Latency)
P95 Latency (ms)     │ $("{0:F2}".PadLeft(16) -f $ChordResults.P95Latency) │ $("{0:F2}".PadLeft(17) -f $KoordeResults.P95Latency)
P99 Latency (ms)     │ $("{0:F2}".PadLeft(16) -f $ChordResults.P99Latency) │ $("{0:F2}".PadLeft(17) -f $KoordeResults.P99Latency)

Cache Performance
═══════════════════════════════════════════════════════════════
Metric               | Chord            | Koorde
─────────────────────┼──────────────────┼───────────────────
Cache Hits           │ $($ChordResults.CacheHits.ToString().PadLeft(16)) │ $($KoordeResults.CacheHits.ToString().PadLeft(17))
Cache Misses         │ $($ChordResults.CacheMisses.ToString().PadLeft(16)) │ $($KoordeResults.CacheMisses.ToString().PadLeft(17))
Cache Hit Rate       │ $("{0:P2}".PadLeft(16) -f $ChordResults.CacheHitRate) │ $("{0:P2}".PadLeft(17) -f $KoordeResults.CacheHitRate)
Total Cache Entries  │ $($ChordMetrics.CacheMetrics.Entries.ToString().PadLeft(16)) │ $($KoordeMetrics.CacheMetrics.Entries.ToString().PadLeft(17))
Total Cache Size     │ $("{0:N0} KB".PadLeft(16) -f ($ChordMetrics.CacheMetrics.SizeBytes/1KB)) │ $("{0:N0} KB".PadLeft(17) -f ($KoordeMetrics.CacheMetrics.SizeBytes/1KB))

 Routing Table Metrics
═══════════════════════════════════════════════════════════════
Metric               | Chord            | Koorde
─────────────────────┼──────────────────┼───────────────────
Avg Successors       │ $("{0:F1}".PadLeft(16) -f (($ChordMetrics.Nodes | ForEach-Object { $_.Routing.SuccessorCount } | Measure-Object -Average).Average)) │ $("{0:F1}".PadLeft(17) -f (($KoordeMetrics.Nodes | ForEach-Object { $_.Routing.SuccessorCount } | Measure-Object -Average).Average))
Avg DeBruijn Entries │ $("0".PadLeft(16)) │ $("{0:F1}".PadLeft(17) -f (($KoordeMetrics.Nodes | ForEach-Object { $_.Routing.DeBruijnCount } | Measure-Object -Average).Average))
Routing Table Size   │ O(log n)         │ O(log² n)
Lookup Hops          │ O(log n)         │ O(log₈ n) ≈ 3-4

============================================
  Performance Comparison
============================================

Latency Improvement: $("{0:F1}%" -f (($ChordResults.AvgLatency - $KoordeResults.AvgLatency) / $ChordResults.AvgLatency * 100))
Cache Hit Rate Diff: $("{0:F2}%" -f (($KoordeResults.CacheHitRate - $ChordResults.CacheHitRate) * 100))

============================================
  Analysis
============================================

"@
    
    # Add analysis
    if ($KoordeResults.AvgLatency -lt $ChordResults.AvgLatency) {
        $report += "✓ Koorde has lower average latency`n"
    } else {
        $report += "✓ Chord has lower average latency`n"
    }
    
    if ($KoordeResults.CacheHitRate -gt $ChordResults.CacheHitRate) {
        $report += "✓ Koorde achieves higher cache hit rate`n"
    } else {
        $report += "✓ Chord achieves higher cache hit rate`n"
    }
    
    $report += "`n"
    $report += "Routing Table Overhead:`n"
    $report += "  - Chord: O(log n) finger table entries`n"
    $report += "  - Koorde: O(log² n) de Bruijn + successor list`n"
    $report += "`n"
    $report += "Lookup Efficiency:`n"
    $report += "  - Chord: O(log n) hops (finger table routing)`n"
    $report += "  - Koorde: O(log₈ n) ≈ 3-4 hops (de Bruijn routing with k=8)`n"
    
    return $report
}

# Main benchmark execution
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Phase 1: Chord Benchmark" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

$chordJobs = Start-Cluster -Protocol "chord" -BaseGrpcPort 5000 -BaseHttpPort 9000
    $chordResultsFile = Run-Benchmark -Protocol "chord" -HttpPort 9000 -OutputFile "benchmark/results/chord-results.csv"
    Write-Host "  Waiting 5 seconds before collecting metrics..." -ForegroundColor Yellow
    Start-Sleep -Seconds 5
    Write-Host "  Collecting metrics from Chord cluster..." -ForegroundColor Yellow
    $chordMetrics = Collect-Metrics -Protocol "chord" -BaseHttpPort 9000
Stop-Cluster -Jobs $chordJobs

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Phase 2: Koorde Benchmark" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

Start-Sleep -Seconds 5  # Brief pause between tests

$koordeJobs = Start-Cluster -Protocol "koorde" -BaseGrpcPort 6000 -BaseHttpPort 10000
    $koordeResultsFile = Run-Benchmark -Protocol "koorde" -HttpPort 10000 -OutputFile "benchmark/results/koorde-results.csv"
    Write-Host "  Waiting 5 seconds before collecting metrics..." -ForegroundColor Yellow
    Start-Sleep -Seconds 5
    Write-Host "  Collecting metrics from Koorde cluster..." -ForegroundColor Yellow
    $koordeMetrics = Collect-Metrics -Protocol "koorde" -BaseHttpPort 10000
Stop-Cluster -Jobs $koordeJobs

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Phase 3: Analysis" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

$chordResults = Parse-Results -CsvFile $chordResultsFile
$koordeResults = Parse-Results -CsvFile $koordeResultsFile

if ($null -eq $chordResults -or $null -eq $koordeResults) {
    Write-Host "⚠ Error: Could not parse results. Check CSV files." -ForegroundColor Red
    exit 1
}

$report = Generate-Report -ChordResults $chordResults -KoordeResults $koordeResults -ChordMetrics $chordMetrics -KoordeMetrics $koordeMetrics

Write-Host $report

# Save report
$reportFile = "benchmark/results/comparison-report.txt"
$report | Out-File -FilePath $reportFile -Encoding utf8
Write-Host ""
Write-Host "Full report saved to: $reportFile" -ForegroundColor Green

# Export JSON summary
$summary = @{
    Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Configuration = @{
        Nodes = $NumNodes
        Requests = $NumRequests
        Concurrency = $Concurrency
        ZipfExponent = $ZipfExponent
    }
    Chord = @{
        Results = $chordResults
        Metrics = $chordMetrics
    }
    Koorde = @{
        Results = $koordeResults
        Metrics = $koordeMetrics
    }
}

$summary | ConvertTo-Json -Depth 10 | Out-File -FilePath "benchmark/results/summary.json" -Encoding utf8
Write-Host "JSON summary saved to: benchmark/results/summary.json" -ForegroundColor Green

Write-Host ""
Write-Host "Benchmark complete!" -ForegroundColor Green

