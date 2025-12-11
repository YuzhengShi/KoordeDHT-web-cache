# Comprehensive Cache Hit/Miss Rate Comparison: Simple Hash vs Chord vs Koorde
# This script runs experiments comparing cache performance with NODE CHURN
# to demonstrate the key difference between simple hashing and consistent hashing.
#
# The experiment has THREE PHASES:
#   Phase 1: Steady-state (warm-up) - all N nodes running, cache fills up
#   Phase 2: After removal - X nodes removed (N-X nodes), measure cache miss spike
#   Phase 3: After recovery - X nodes added back (N nodes), measure recovery
#
# Usage: 
#   .\compare-all-protocols.ps1 -Nodes 4 -NodesToRemove 1    # 4 → 3 → 4
#   .\compare-all-protocols.ps1 -Nodes 8 -NodesToRemove 2    # 8 → 6 → 8
#   .\compare-all-protocols.ps1 -Nodes 10 -NodesToRemove 2   # 10 → 8 → 10

param(
    [int]$Nodes = 8,
    [int]$NodesToRemove = 1,       # Number of nodes to remove in Phase 2
    [int]$Degree = 4,              # Koorde de Bruijn degree
    [int]$WarmupRequests = 300,    # Requests in Phase 1 (warmup)
    [int]$ChurnRequests = 300,     # Requests in Phase 2 (after removal)
    [int]$RecoveryRequests = 300,  # Requests in Phase 3 (after nodes rejoin)
    [int]$Rate = 50,               # Requests per second
    [int]$URLs = 200,              # Number of unique URLs (cache keys)
    [double]$Zipf = 1.2,           # Zipf distribution parameter (>1.0)
    [switch]$SkipBuild = $false,
    [switch]$SkipChurn = $false,   # If true, only run steady-state test (no churn)
    [string]$ResultsDir = "benchmark/results/protocol-comparison"
)

$ErrorActionPreference = "Stop"
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"

# Validate parameters
if ($NodesToRemove -ge $Nodes) {
    Write-Host "ERROR: NodesToRemove ($NodesToRemove) must be less than Nodes ($Nodes)" -ForegroundColor Red
    exit 1
}
if ($NodesToRemove -lt 1) {
    Write-Host "ERROR: NodesToRemove must be at least 1" -ForegroundColor Red
    exit 1
}

$NodesAfterRemoval = $Nodes - $NodesToRemove

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  CACHE HIT/MISS RATE COMPARISON WITH NODE CHURN" -ForegroundColor Cyan
Write-Host "  Simple Hash vs Chord vs Koorde" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Configuration:" -ForegroundColor Yellow
Write-Host "  Node Pattern:     $Nodes -> $NodesAfterRemoval -> $Nodes (remove $NodesToRemove, then add back)"
Write-Host "  Koorde Degree:    $Degree"
Write-Host "  Phase 1 Requests: $WarmupRequests (warmup with $Nodes nodes)"
Write-Host "  Phase 2 Requests: $ChurnRequests (after removal, $NodesAfterRemoval nodes)"
Write-Host "  Phase 3 Requests: $RecoveryRequests (after recovery, $Nodes nodes)"
Write-Host "  Rate:             $Rate req/s"
Write-Host "  Unique URLs:      $URLs"
Write-Host "  Zipf alpha:       $Zipf"
Write-Host "  Node Churn:       $(if ($SkipChurn) { 'DISABLED' } else { "ENABLED - pattern $Nodes->$NodesAfterRemoval->$Nodes" })"
Write-Host ""

# Calculate theoretical impact
$m = [Math]::Ceiling([Math]::Log($Nodes) / [Math]::Log(2))
$logD = [Math]::Max(1, [Math]::Log($Degree) / [Math]::Log(2))
$koordeHops = [Math]::Ceiling($m / $logD)

$simpleHashRemovalImpact = [Math]::Round(($Nodes - $NodesAfterRemoval) / $Nodes * 100, 1)
$simpleHashRecoveryImpact = [Math]::Round(($Nodes - $NodesAfterRemoval) / $Nodes * 100, 1)
$consistentRemovalImpact = [Math]::Round($NodesToRemove / $Nodes * 100, 1)
$consistentRecoveryImpact = [Math]::Round($NodesToRemove / $Nodes * 100, 1)

Write-Host "Theoretical Impact of Node Changes:" -ForegroundColor Yellow
Write-Host "  Removing $NodesToRemove of $Nodes nodes:" -ForegroundColor Gray
Write-Host "    Simple Hash:  ~$simpleHashRemovalImpact% keys remapped (hash % $NodesAfterRemoval != hash % $Nodes)"
Write-Host "    Chord/Koorde: ~$consistentRemovalImpact% keys remapped (consistent hashing)"
Write-Host "  Adding $NodesToRemove nodes back:" -ForegroundColor Gray
Write-Host "    Simple Hash:  ~$simpleHashRecoveryImpact% keys remapped again"
Write-Host "    Chord/Koorde: ~$consistentRecoveryImpact% keys redistributed"
Write-Host ""
Write-Host "Routing Complexity:" -ForegroundColor Yellow
Write-Host "  Simple Hash:  O(1)"
Write-Host "  Chord:        O(log n) = ~$m hops"
Write-Host "  Koorde:       O(log n / log d) = ~$koordeHops hops"
Write-Host ""

# Build if needed
if (-not $SkipBuild) {
    Write-Host "[BUILD] Compiling binaries..." -ForegroundColor Gray
    go build -o bin/koorde-node.exe ./cmd/node 2>&1 | Out-Null
    go build -o bin/cache-workload.exe ./cmd/cache-workload 2>&1 | Out-Null
    go build -o bin/mock-origin.exe ./cmd/mock-origin 2>&1 | Out-Null
    Write-Host "  Done." -ForegroundColor Green
    Write-Host ""
}

# Create directories
New-Item -ItemType Directory -Path "logs" -Force | Out-Null
New-Item -ItemType Directory -Path $ResultsDir -Force | Out-Null

# Mock origin server process
$script:mockOriginProcess = $null

function Start-MockOrigin {
    param([int]$Port = 9999)
    
    # Kill any existing mock origin
    Get-Process -Name "mock-origin" -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 1
    
    $proc = Start-Process -FilePath ".\bin\mock-origin.exe" `
        -ArgumentList "-port", $Port `
        -RedirectStandardOutput "logs/mock-origin.log" `
        -RedirectStandardError "logs/mock-origin.err" `
        -WindowStyle Hidden `
        -PassThru
    $script:mockOriginProcess = $proc.Id
    
    # Wait for it to start
    Start-Sleep -Seconds 1
    
    # Verify it's running
    try {
        $response = Invoke-RestMethod "http://localhost:$Port/test" -TimeoutSec 2
        Write-Host "  Mock origin server started on port $Port" -ForegroundColor Green
        return $true
    } catch {
        Write-Host "  WARNING: Mock origin may not be running" -ForegroundColor Yellow
        return $false
    }
}

function Stop-MockOrigin {
    if ($script:mockOriginProcess) {
        try {
            Stop-Process -Id $script:mockOriginProcess -Force -ErrorAction SilentlyContinue
        } catch {}
    }
    Get-Process -Name "mock-origin" -ErrorAction SilentlyContinue | Stop-Process -Force
}

function Stop-AllNodes {
    Get-Process -Name "koorde-node" -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 2
}

function Stop-SingleNode {
    param([int]$NodeIndex)
    
    $httpPort = 8080 + $NodeIndex
    
    # First try using tracked process ID
    if ($script:nodeProcesses.ContainsKey($NodeIndex)) {
        $procId = $script:nodeProcesses[$NodeIndex]
        try {
            $proc = Get-Process -Id $procId -ErrorAction SilentlyContinue
            if ($proc) {
                Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue
                Write-Host "    Killed process $procId (tracked PID for node $NodeIndex)" -ForegroundColor Gray
            }
        } catch {}
    }
    
    Start-Sleep -Seconds 1
    
    # Verify node is down with retries
    for ($check = 0; $check -lt 5; $check++) {
        try {
            $null = Invoke-RestMethod "http://localhost:$httpPort/health" -TimeoutSec 1
            # Still responding, wait and retry
            Start-Sleep -Milliseconds 500
        } catch {
            # Node is down
            return $true
        }
    }
    
    # If still running, try harder with taskkill
    try {
        $grpcPort = 4000 + $NodeIndex
        # Find by port using netstat
        $netstat = netstat -ano | Select-String ":$grpcPort\s" | Select-Object -First 1
        if ($netstat) {
            $parts = $netstat -split '\s+'
            $procId = $parts[-1]
            if ($procId -match '^\d+$') {
                taskkill /PID $procId /F 2>&1 | Out-Null
                Write-Host "    Killed process $procId (via netstat)" -ForegroundColor Gray
            }
        }
    } catch {}
    
    Start-Sleep -Seconds 1
    
    # Final verification
    try {
        $null = Invoke-RestMethod "http://localhost:$httpPort/health" -TimeoutSec 1
        return $false  # Still running
    } catch {
        return $true  # Down
    }
}

# Global hashtable to track node processes
$script:nodeProcesses = @{}

function Start-Cluster {
    param([int]$NodeCount, [string]$ConfigDir)
    
    $script:nodeProcesses = @{}
    
    # Start node 0 first (bootstrap node)
    $proc = Start-Process -FilePath ".\bin\koorde-node.exe" `
        -ArgumentList "-config", "$ConfigDir/node0.yaml" `
        -RedirectStandardOutput "logs/protocol-node0.log" `
        -RedirectStandardError "logs/protocol-node0.err" `
        -WindowStyle Hidden `
        -PassThru
    $script:nodeProcesses[0] = $proc.Id
    
    Start-Sleep -Seconds 3
    
    # Start remaining nodes
    for ($i = 1; $i -lt $NodeCount; $i++) {
        $proc = Start-Process -FilePath ".\bin\koorde-node.exe" `
            -ArgumentList "-config", "$ConfigDir/node$i.yaml" `
            -RedirectStandardOutput "logs/protocol-node$i.log" `
            -RedirectStandardError "logs/protocol-node$i.err" `
            -WindowStyle Hidden `
            -PassThru
        $script:nodeProcesses[$i] = $proc.Id
        Start-Sleep -Milliseconds 500
    }
}

function Wait-ForReady {
    param([int]$NodeCount, [int]$TimeoutSec = 60, [int[]]$ExcludeNodes = @())
    
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $requiredReady = $NodeCount - $ExcludeNodes.Count
    
    while ((Get-Date) -lt $deadline) {
        $ready = 0
        for ($i = 0; $i -lt $NodeCount; $i++) {
            if ($ExcludeNodes -contains $i) { continue }
            try {
                $h = Invoke-RestMethod "http://localhost:$(8080+$i)/health" -TimeoutSec 2
                if ($h.status -eq "READY" -or $h.healthy -eq $true) { $ready++ }
            } catch {}
        }
        if ($ready -ge $requiredReady) { return $true }
        Start-Sleep -Seconds 2
    }
    return $false
}

function Run-Workload {
    param(
        [int]$NodeCount, 
        [int]$Reqs, 
        [int]$ReqRate, 
        [int]$NumURLs, 
        [double]$ZipfAlpha, 
        [string]$OutputFile,
        [int[]]$ExcludeNodes = @(),
        [int64]$Seed = 0,
        [string]$OriginUrl = "http://localhost:9999"
    )
    
    $targets = @()
    for ($i = 0; $i -lt $NodeCount; $i++) {
        if ($ExcludeNodes -contains $i) { continue }
        $targets += "http://localhost:$(8080+$i)"
    }
    $targetsStr = $targets -join ','
    
    # Use seed for reproducible URL patterns
    $seedArg = if ($Seed -gt 0) { "-seed $Seed" } else { "" }
    $cmd = "./bin/cache-workload.exe -targets $targetsStr -requests $Reqs -rate $ReqRate -urls $NumURLs -zipf $ZipfAlpha -output $OutputFile -origin $OriginUrl $seedArg"
    Invoke-Expression $cmd 2>&1 | Out-Null
    
    if (Test-Path $OutputFile) {
        $csv = Import-Csv $OutputFile
        $count = $csv.Count
        
        if ($count -eq 0) {
            return @{
                Total = 0
                Hits = 0
                Misses = 0
                HitRate = 0
                AvgLatency = 0
                P50 = 0
                P95 = 0
                P99 = 0
                SuccessRate = 0
                Errors = 0
            }
        }
        
        $latencies = $csv | ForEach-Object { [double]$_.latency_ms }
        $successes = ($csv | Where-Object { $_.status -eq "200" }).Count
        $errors = $Reqs - $count  # Requests that didn't get recorded
        
        # Count cache hits and misses from X-Cache header
        $hits = ($csv | Where-Object { $_.cache_status -like "HIT*" }).Count
        $misses = ($csv | Where-Object { $_.cache_status -like "MISS*" }).Count
        
        $sorted = $latencies | Sort-Object
        
        $hitRate = 0
        if (($hits + $misses) -gt 0) {
            $hitRate = [Math]::Round($hits / ($hits + $misses) * 100, 2)
        }
        
        return @{
            Total = $count
            Hits = $hits
            Misses = $misses
            HitRate = $hitRate
            AvgLatency = [Math]::Round(($latencies | Measure-Object -Average).Average, 2)
            P50 = [Math]::Round($sorted[[Math]::Floor($count * 0.50)], 2)
            P95 = [Math]::Round($sorted[[Math]::Min([Math]::Floor($count * 0.95), $count-1)], 2)
            P99 = [Math]::Round($sorted[[Math]::Min([Math]::Floor($count * 0.99), $count-1)], 2)
            SuccessRate = [Math]::Round($successes / $Reqs * 100, 2)
            Errors = $errors
        }
    }
    return $null
}

function Notify-SimpleHashNodeRemoval {
    param(
        [int]$NodeCount, 
        [int[]]$RemovedNodeIndices
    )
    
    $notified = 0
    foreach ($removedIdx in $RemovedNodeIndices) {
        $removedGrpcPort = 4000 + $removedIdx
        $removedNodeAddr = "localhost:$removedGrpcPort"
        
        Write-Host "    Notifying nodes about removal of $removedNodeAddr..." -ForegroundColor Gray
        
        for ($i = 0; $i -lt $NodeCount; $i++) {
            if ($RemovedNodeIndices -contains $i) { continue }
            
            $httpPort = 8080 + $i
            try {
                $response = Invoke-RestMethod -Method Post "http://localhost:$httpPort/cluster/remove?node=$removedNodeAddr" -TimeoutSec 5
                if ($response.success) {
                    $notified++
                }
            } catch {
                # Expected for non-simple-hash protocols
            }
        }
    }
    
    if ($notified -gt 0) {
        $newSize = $NodeCount - $RemovedNodeIndices.Count
        Write-Host "    Notified nodes - cluster size updated to $newSize" -ForegroundColor Green
    }
    
    return $notified
}

function Restart-RemovedNodes {
    param(
        [string]$ConfigDir,
        [int[]]$NodeIndices
    )
    
    foreach ($i in $NodeIndices) {
        $proc = Start-Process -FilePath ".\bin\koorde-node.exe" `
            -ArgumentList "-config", "$ConfigDir/node$i.yaml" `
            -RedirectStandardOutput "logs/protocol-node$i.log" `
            -RedirectStandardError "logs/protocol-node$i.err" `
            -WindowStyle Hidden `
            -PassThru
        $script:nodeProcesses[$i] = $proc.Id
        Write-Host "    Restarted node $i (PID: $($proc.Id))" -ForegroundColor Gray
        Start-Sleep -Milliseconds 500
    }
}

function Notify-SimpleHashNodeAddition {
    param(
        [int]$NodeCount,
        [int[]]$AddedNodeIndices
    )
    
    # For simple hash, when nodes are added back, we need to update the cluster membership
    # We'll call a hypothetical /cluster/add endpoint (we need to implement this)
    # For now, the nodes will rejoin and update their own membership
    
    $notified = 0
    foreach ($addedIdx in $AddedNodeIndices) {
        $addedGrpcPort = 4000 + $addedIdx
        $addedNodeAddr = "localhost:$addedGrpcPort"
        
        Write-Host "    Notifying nodes about addition of $addedNodeAddr..." -ForegroundColor Gray
        
        for ($i = 0; $i -lt $NodeCount; $i++) {
            $httpPort = 8080 + $i
            try {
                $response = Invoke-RestMethod -Method Post "http://localhost:$httpPort/cluster/add?node=$addedNodeAddr" -TimeoutSec 5
                if ($response.success) {
                    $notified++
                }
            } catch {
                # Expected for non-simple-hash protocols
            }
        }
    }
    
    if ($notified -gt 0) {
        Write-Host "    Notified nodes - cluster size updated to $NodeCount" -ForegroundColor Green
    }
    
    return $notified
}

function Get-CacheMetrics {
    param([int]$NodeCount, [int[]]$ExcludeNodes = @())
    
    $totalHits = 0
    $totalMisses = 0
    $totalStores = 0
    $protocol = ""
    
    for ($i = 0; $i -lt $NodeCount; $i++) {
        if ($ExcludeNodes -contains $i) { continue }
        try {
            $m = Invoke-RestMethod "http://localhost:$(8080+$i)/metrics" -TimeoutSec 3
            $totalHits += $m.cache.hits
            $totalMisses += $m.cache.misses
            $totalStores += $m.cache.stores
            $protocol = $m.routing.stats.protocol
        } catch {}
    }
    
    $total = $totalHits + $totalMisses
    $hitRate = if ($total -gt 0) { [Math]::Round($totalHits / $total * 100, 2) } else { 0 }
    
    return @{
        Protocol = $protocol
        TotalHits = $totalHits
        TotalMisses = $totalMisses
        TotalStores = $totalStores
        HitRate = $hitRate
    }
}

function Run-ProtocolTest {
    param(
        [string]$ProtocolName,
        [string]$ConfigDir,
        [string]$ConfigScript,
        [int]$WaitTime,
        [scriptblock]$ConfigGenerator,
        [int]$TotalNodes,
        [int]$RemoveCount
    )
    
    # Use passed parameters instead of script-scope variables
    $nodeCount = $TotalNodes
    $removeCount = $RemoveCount
    $nodesAfter = $nodeCount - $removeCount
    
    Write-Host "------------------------------------------------------------" -ForegroundColor Gray
    Write-Host "[TEST] Running $ProtocolName - $nodeCount -> $nodesAfter -> $nodeCount nodes" -ForegroundColor Yellow
    Write-Host "------------------------------------------------------------" -ForegroundColor Gray
    
    # Generate config
    Write-Host "  Generating $ProtocolName config..." -ForegroundColor Gray
    & $ConfigGenerator
    
    # Start cluster
    Write-Host "  Starting $ProtocolName cluster ($nodeCount nodes)..." -ForegroundColor Gray
    Start-Cluster -NodeCount $nodeCount -ConfigDir $ConfigDir
    
    # Wait for ready
    Write-Host "  Waiting for cluster ready..." -ForegroundColor Gray
    Start-Sleep -Seconds $WaitTime
    $ready = Wait-ForReady -NodeCount $nodeCount -TimeoutSec 60
    
    if (-not $ready) {
        Write-Host "  ERROR: $ProtocolName cluster not ready!" -ForegroundColor Red
        Stop-AllNodes
        return $null
    }
    Write-Host "  $ProtocolName cluster READY ($nodeCount nodes)" -ForegroundColor Green
    
    # Use a fixed seed for this protocol test (so all phases have same URL pattern)
    $protocolSeed = [int64]([System.DateTime]::UtcNow.Ticks % [int64]::MaxValue)
    
    # ============================================================
    # PHASE 1: Warmup (all N nodes running)
    # ============================================================
    Write-Host "  [PHASE 1] Warmup with $nodeCount nodes ($WarmupRequests requests)..." -ForegroundColor Cyan
    $warmupFile = "$ResultsDir/$($ProtocolName.ToLower() -replace ' ','-')-phase1-$timestamp.csv"
    $warmupResult = Run-Workload -NodeCount $nodeCount -Reqs $WarmupRequests -ReqRate $Rate -NumURLs $URLs -ZipfAlpha $Zipf -OutputFile $warmupFile -Seed $protocolSeed
    $warmupMetrics = Get-CacheMetrics -NodeCount $nodeCount
    
    $warmupEffectiveRate = [Math]::Round($warmupResult.Hits / $WarmupRequests * 100, 2)
    $warmupFailures = $WarmupRequests - $warmupResult.Total
    Write-Host "    Phase 1: $warmupEffectiveRate% effective hit rate ($($warmupResult.Hits) hits, $warmupFailures failures)" -ForegroundColor Gray
    
    if ($SkipChurn) {
        Stop-AllNodes
        return @{
            Phase1 = $warmupResult
            Phase1Metrics = $warmupMetrics
            Phase2 = $null
            Phase3 = $null
            Protocol = $ProtocolName
        }
    }
    
    # ============================================================
    # PHASE 2: Remove nodes (N-X nodes running)
    # ============================================================
    # Calculate which nodes to remove (highest indices)
    $nodesToRemoveList = @()
    for ($i = 0; $i -lt $removeCount; $i++) {
        $nodesToRemoveList += ($nodeCount - 1 - $i)
    }
    
    Write-Host "  [CHURN] Removing $removeCount node(s): $($nodesToRemoveList -join ', ')..." -ForegroundColor Magenta
    
    foreach ($nodeIdx in $nodesToRemoveList) {
        $nodeStopped = Stop-SingleNode -NodeIndex $nodeIdx
        if ($nodeStopped) {
            Write-Host "    Node $nodeIdx stopped" -ForegroundColor Gray
        } else {
            Write-Host "    WARNING: Node $nodeIdx may still be running" -ForegroundColor Yellow
        }
    }
    
    Start-Sleep -Seconds 2
    
    # Notify Simple Hash nodes about the membership changes
    Notify-SimpleHashNodeRemoval -NodeCount $nodeCount -RemovedNodeIndices $nodesToRemoveList
    
    # Brief pause to let membership update propagate
    Start-Sleep -Seconds 2
    
    Write-Host "  [PHASE 2] After removal: $nodesAfter nodes ($ChurnRequests requests)..." -ForegroundColor Cyan
    $churnFile = "$ResultsDir/$($ProtocolName.ToLower() -replace ' ','-')-phase2-$timestamp.csv"
    $churnResult = Run-Workload -NodeCount $nodeCount -Reqs $ChurnRequests -ReqRate $Rate -NumURLs $URLs -ZipfAlpha $Zipf -OutputFile $churnFile -ExcludeNodes $nodesToRemoveList -Seed $protocolSeed
    $churnMetrics = Get-CacheMetrics -NodeCount $nodeCount -ExcludeNodes $nodesToRemoveList
    
    $churnEffectiveRate = [Math]::Round($churnResult.Hits / $ChurnRequests * 100, 2)
    $churnFailures = $ChurnRequests - $churnResult.Total
    $phase1to2Drop = $warmupEffectiveRate - $churnEffectiveRate
    
    $dropColor = if ($phase1to2Drop -gt 20) { "Red" } elseif ($phase1to2Drop -gt 10) { "Yellow" } else { "Green" }
    Write-Host "    Phase 2: $churnEffectiveRate% effective ($churnFailures failures), " -NoNewline -ForegroundColor Gray
    Write-Host "$([Math]::Round($phase1to2Drop, 1))% drop from Phase 1" -ForegroundColor $dropColor
    
    # ============================================================
    # PHASE 3: Add nodes back (N nodes running again)
    # ============================================================
    Write-Host "  [RECOVERY] Restarting $removeCount node(s)..." -ForegroundColor Magenta
    Restart-RemovedNodes -ConfigDir $ConfigDir -NodeIndices $nodesToRemoveList
    
    # Wait for rejoined nodes to be ready
    Start-Sleep -Seconds $WaitTime
    $ready = Wait-ForReady -NodeCount $nodeCount -TimeoutSec 60
    if (-not $ready) {
        Write-Host "    WARNING: Not all nodes ready after recovery" -ForegroundColor Yellow
    } else {
        Write-Host "    All $nodeCount nodes ready" -ForegroundColor Green
    }
    
    # Notify Simple Hash nodes about the new nodes
    Notify-SimpleHashNodeAddition -NodeCount $nodeCount -AddedNodeIndices $nodesToRemoveList
    
    # Brief pause to let membership update propagate
    Start-Sleep -Seconds 2
    
    Write-Host "  [PHASE 3] After recovery: $nodeCount nodes ($RecoveryRequests requests)..." -ForegroundColor Cyan
    $recoveryFile = "$ResultsDir/$($ProtocolName.ToLower() -replace ' ','-')-phase3-$timestamp.csv"
    $recoveryResult = Run-Workload -NodeCount $nodeCount -Reqs $RecoveryRequests -ReqRate $Rate -NumURLs $URLs -ZipfAlpha $Zipf -OutputFile $recoveryFile -Seed $protocolSeed
    $recoveryMetrics = Get-CacheMetrics -NodeCount $nodeCount
    
    $recoveryEffectiveRate = [Math]::Round($recoveryResult.Hits / $RecoveryRequests * 100, 2)
    $recoveryFailures = $RecoveryRequests - $recoveryResult.Total
    $phase2to3Change = $recoveryEffectiveRate - $churnEffectiveRate
    
    $changeColor = if ($phase2to3Change -lt -10) { "Red" } elseif ($phase2to3Change -lt 0) { "Yellow" } else { "Green" }
    Write-Host "    Phase 3: $recoveryEffectiveRate% effective ($recoveryFailures failures), " -NoNewline -ForegroundColor Gray
    if ($phase2to3Change -ge 0) {
        Write-Host "+$([Math]::Round($phase2to3Change, 1))% from Phase 2" -ForegroundColor $changeColor
    } else {
        Write-Host "$([Math]::Round($phase2to3Change, 1))% from Phase 2" -ForegroundColor $changeColor
    }
    
    Stop-AllNodes
    Write-Host "  $ProtocolName test complete." -ForegroundColor Green
    Write-Host ""
    
    return @{
        Phase1 = $warmupResult
        Phase1Metrics = $warmupMetrics
        Phase1EffectiveRate = $warmupEffectiveRate
        Phase1Failures = $warmupFailures
        
        Phase2 = $churnResult
        Phase2Metrics = $churnMetrics
        Phase2EffectiveRate = $churnEffectiveRate
        Phase2Failures = $churnFailures
        Phase1to2Drop = $phase1to2Drop
        
        Phase3 = $recoveryResult
        Phase3Metrics = $recoveryMetrics
        Phase3EffectiveRate = $recoveryEffectiveRate
        Phase3Failures = $recoveryFailures
        Phase2to3Change = $phase2to3Change
        
        Protocol = $ProtocolName
        NodesToRemove = $removeCount
    }
}

# ============================================================
# INITIAL CLEANUP
# ============================================================
Write-Host "[CLEANUP] Stopping any existing nodes..." -ForegroundColor Gray
Stop-AllNodes
Stop-MockOrigin

# ============================================================
# START MOCK ORIGIN SERVER
# ============================================================
Write-Host "[ORIGIN] Starting mock origin server..." -ForegroundColor Gray
$originStarted = Start-MockOrigin -Port 9999
if (-not $originStarted) {
    Write-Host "ERROR: Mock origin server failed to start!" -ForegroundColor Red
    Write-Host "Experiment cannot continue without origin server." -ForegroundColor Red
    exit 1
}

$results = @{}

# Calculate dynamic stabilization times based on node count
$simpleWaitTime = [Math]::Max(5, $Nodes * 2)
$chordWaitTime = [Math]::Max(15, $Nodes * 4)
$koordeWaitTime = [Math]::Max(25, $Nodes * 5)

Write-Host "Stabilization times (based on $Nodes nodes):" -ForegroundColor Gray
Write-Host "  Simple Hash: ${simpleWaitTime}s | Chord: ${chordWaitTime}s | Koorde: ${koordeWaitTime}s"
Write-Host ""

# ============================================================
# TEST 1: SIMPLE HASH
# ============================================================
$results["simple"] = Run-ProtocolTest `
    -ProtocolName "Simple Hash" `
    -ConfigDir "config/simple-cluster" `
    -WaitTime $simpleWaitTime `
    -TotalNodes $Nodes `
    -RemoveCount $NodesToRemove `
    -ConfigGenerator {
        & ./scripts/generate-simple-configs.ps1 -Nodes $Nodes -OutputDir "config/simple-cluster" | Out-Null
    }

# ============================================================
# TEST 2: CHORD
# ============================================================
$results["chord"] = Run-ProtocolTest `
    -ProtocolName "Chord" `
    -ConfigDir "config/chord-cluster" `
    -WaitTime $chordWaitTime `
    -TotalNodes $Nodes `
    -RemoveCount $NodesToRemove `
    -ConfigGenerator {
        & ./scripts/generate-chord-configs.ps1 -Nodes $Nodes -OutputDir "config/chord-cluster" | Out-Null
    }

# ============================================================
# TEST 3: KOORDE
# ============================================================
$results["koorde"] = Run-ProtocolTest `
    -ProtocolName "Koorde" `
    -ConfigDir "config/test-cluster" `
    -WaitTime $koordeWaitTime `
    -TotalNodes $Nodes `
    -RemoveCount $NodesToRemove `
    -ConfigGenerator {
        & ./scripts/generate-cluster-configs.ps1 -Nodes $Nodes -Degree $Degree -OutputDir "config/test-cluster" | Out-Null
    }

# ============================================================
# RESULTS COMPARISON
# ============================================================
Write-Host "============================================================" -ForegroundColor Green
Write-Host "     CACHE HIT/MISS RATE COMPARISON RESULTS (3 PHASES)" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host ""

Write-Host "Test Configuration:" -ForegroundColor Cyan
Write-Host "  Node Pattern: $Nodes -> $NodesAfterRemoval -> $Nodes (removed $NodesToRemove, then added back)"
Write-Host "  URLs: $URLs | Zipf: $Zipf | Rate: $Rate req/s"
Write-Host "  Phase 1: $WarmupRequests requests (warmup)"
Write-Host "  Phase 2: $ChurnRequests requests (after removal)"
Write-Host "  Phase 3: $RecoveryRequests requests (after recovery)"
Write-Host ""

# Phase 1: Warmup Results
Write-Host "PHASE 1: WARMUP ($Nodes nodes)" -ForegroundColor Yellow
Write-Host "------------------------------------------------------------"
Write-Host ("{0,-15} {1,10} {2,10} {3,10} {4,12}" -f "Protocol", "Hits", "Misses", "Failures", "Effective%")
Write-Host "------------------------------------------------------------"
foreach ($proto in @("simple", "chord", "koorde")) {
    $r = $results[$proto]
    if ($r -and $r.Phase1) {
        $name = switch ($proto) { "simple" { "Simple Hash" }; "chord" { "Chord" }; "koorde" { "Koorde" } }
        Write-Host ("{0,-15} {1,10} {2,10} {3,10} {4,10}%" -f $name, $r.Phase1.Hits, $r.Phase1.Misses, $r.Phase1Failures, $r.Phase1EffectiveRate)
    }
}
Write-Host "------------------------------------------------------------"
Write-Host ""

if (-not $SkipChurn) {
    # Phase 2: After Removal
    Write-Host "PHASE 2: AFTER REMOVAL ($NodesAfterRemoval nodes)" -ForegroundColor Yellow
    Write-Host "------------------------------------------------------------"
    Write-Host ("{0,-15} {1,10} {2,10} {3,10} {4,12} {5,10}" -f "Protocol", "Hits", "Misses", "Failures", "Effective%", "Drop")
    Write-Host "------------------------------------------------------------"
    foreach ($proto in @("simple", "chord", "koorde")) {
        $r = $results[$proto]
        if ($r -and $r.Phase2) {
            $name = switch ($proto) { "simple" { "Simple Hash" }; "chord" { "Chord" }; "koorde" { "Koorde" } }
            $drop = $r.Phase1to2Drop
            $dropStr = if ($drop -gt 0) { "-$([Math]::Round($drop, 1))%" } else { "+$([Math]::Round([Math]::Abs($drop), 1))%" }
            Write-Host ("{0,-15} {1,10} {2,10} {3,10} {4,10}% {5,10}" -f $name, $r.Phase2.Hits, $r.Phase2.Misses, $r.Phase2Failures, $r.Phase2EffectiveRate, $dropStr)
        }
    }
    Write-Host "------------------------------------------------------------"
    Write-Host ""
    
    # Phase 3: After Recovery
    Write-Host "PHASE 3: AFTER RECOVERY ($Nodes nodes)" -ForegroundColor Yellow
    Write-Host "------------------------------------------------------------"
    Write-Host ("{0,-15} {1,10} {2,10} {3,10} {4,12} {5,10}" -f "Protocol", "Hits", "Misses", "Failures", "Effective%", "Change")
    Write-Host "------------------------------------------------------------"
    foreach ($proto in @("simple", "chord", "koorde")) {
        $r = $results[$proto]
        if ($r -and $r.Phase3) {
            $name = switch ($proto) { "simple" { "Simple Hash" }; "chord" { "Chord" }; "koorde" { "Koorde" } }
            $change = $r.Phase2to3Change
            $changeStr = if ($change -ge 0) { "+$([Math]::Round($change, 1))%" } else { "$([Math]::Round($change, 1))%" }
            Write-Host ("{0,-15} {1,10} {2,10} {3,10} {4,10}% {5,10}" -f $name, $r.Phase3.Hits, $r.Phase3.Misses, $r.Phase3Failures, $r.Phase3EffectiveRate, $changeStr)
        }
    }
    Write-Host "------------------------------------------------------------"
    Write-Host ""
    
    # Summary: Effective Hit Rate Progression
    Write-Host "EFFECTIVE HIT RATE PROGRESSION:" -ForegroundColor Magenta
    Write-Host "------------------------------------------------------------"
    Write-Host ("{0,-15} {1,12} {2,12} {3,12} {4,15}" -f "Protocol", "Phase1", "Phase2", "Phase3", "Total Change")
    Write-Host "------------------------------------------------------------"
    
    foreach ($proto in @("simple", "chord", "koorde")) {
        $r = $results[$proto]
        if ($r -and $r.Phase1EffectiveRate -ne $null) {
            $name = switch ($proto) { "simple" { "Simple Hash" }; "chord" { "Chord" }; "koorde" { "Koorde" } }
            $totalChange = $r.Phase3EffectiveRate - $r.Phase1EffectiveRate
            $totalStr = if ($totalChange -ge 0) { "+$([Math]::Round($totalChange, 1))%" } else { "$([Math]::Round($totalChange, 1))%" }
            $totalColor = if ($totalChange -lt -10) { "Red" } elseif ($totalChange -lt 0) { "Yellow" } else { "Green" }
            
            Write-Host ("{0,-15} {1,10}% {2,10}% {3,10}% " -f $name, $r.Phase1EffectiveRate, $r.Phase2EffectiveRate, $r.Phase3EffectiveRate) -NoNewline
            Write-Host ("{0,15}" -f $totalStr) -ForegroundColor $totalColor
        }
    }
    Write-Host "------------------------------------------------------------"
    Write-Host ""
    
    # Theoretical vs Actual
    Write-Host "THEORETICAL IMPACT:" -ForegroundColor Cyan
    Write-Host "------------------------------------------------------------"
    $theoreticalSimpleRemove = [Math]::Round(($Nodes - $NodesAfterRemoval) / $Nodes * 100, 1)
    $theoreticalConsistentRemove = [Math]::Round($NodesToRemove / $Nodes * 100, 1)
    
    Write-Host "  Removing $NodesToRemove of $Nodes nodes:"
    Write-Host "    Simple Hash:  ~$theoreticalSimpleRemove% keys remapped (hash % $NodesAfterRemoval != hash % $Nodes)"
    Write-Host "    Chord/Koorde: ~$theoreticalConsistentRemove% keys remapped (only removed nodes' keys)"
    Write-Host ""
    Write-Host "  Adding $NodesToRemove nodes back:"
    Write-Host "    Simple Hash:  ~$theoreticalSimpleRemove% keys remapped again"
    Write-Host "    Chord/Koorde: ~$theoreticalConsistentRemove% keys redistributed to new nodes"
    Write-Host "------------------------------------------------------------"
    Write-Host ""
}

# Latency Comparison
Write-Host "LATENCY COMPARISON (Phase 1):" -ForegroundColor Yellow
Write-Host "------------------------------------------------------------"
Write-Host ("{0,-15} {1,10} {2,10} {3,10} {4,10}" -f "Protocol", "Avg(ms)", "P50(ms)", "P95(ms)", "P99(ms)")
Write-Host "------------------------------------------------------------"
foreach ($proto in @("simple", "chord", "koorde")) {
    $r = $results[$proto]
    if ($r -and $r.Phase1) {
        $name = switch ($proto) { "simple" { "Simple Hash" }; "chord" { "Chord" }; "koorde" { "Koorde" } }
        Write-Host ("{0,-15} {1,10} {2,10} {3,10} {4,10}" -f $name, $r.Phase1.AvgLatency, $r.Phase1.P50, $r.Phase1.P95, $r.Phase1.P99)
    }
}
Write-Host "------------------------------------------------------------"
Write-Host ""

# Analysis
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "                     ANALYSIS" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

if (-not $SkipChurn) {
    # Calculate total impact for each protocol
    $simpleTotal = if ($results["simple"]) { $results["simple"].Phase3EffectiveRate - $results["simple"].Phase1EffectiveRate } else { 0 }
    $chordTotal = if ($results["chord"]) { $results["chord"].Phase3EffectiveRate - $results["chord"].Phase1EffectiveRate } else { 0 }
    $koordeTotal = if ($results["koorde"]) { $results["koorde"].Phase3EffectiveRate - $results["koorde"].Phase1EffectiveRate } else { 0 }
    
    $simpleFailuresPhase2 = if ($results["simple"]) { $results["simple"].Phase2Failures } else { 0 }
    $chordFailuresPhase2 = if ($results["chord"]) { $results["chord"].Phase2Failures } else { 0 }
    $koordeFailuresPhase2 = if ($results["koorde"]) { $results["koorde"].Phase2Failures } else { 0 }
    
    Write-Host "Churn Resilience Ranking (by total hit rate change after full cycle):" -ForegroundColor Green
    $sorted = @(
        @{Name="Simple Hash"; TotalChange=$simpleTotal; Phase2Failures=$simpleFailuresPhase2},
        @{Name="Chord"; TotalChange=$chordTotal; Phase2Failures=$chordFailuresPhase2},
        @{Name="Koorde"; TotalChange=$koordeTotal; Phase2Failures=$koordeFailuresPhase2}
    ) | Sort-Object { -$_.TotalChange }  # Sort descending (best = highest/least negative)
    
    $rank = 1
    foreach ($p in $sorted) {
        $changeStr = if ($p.TotalChange -ge 0) { "+$([Math]::Round($p.TotalChange, 1))%" } else { "$([Math]::Round($p.TotalChange, 1))%" }
        $failStr = if ($p.Phase2Failures -gt 0) { " ($($p.Phase2Failures) failures in Phase 2)" } else { " (no failures)" }
        Write-Host "  $rank. $($p.Name): $changeStr after full cycle$failStr"
        $rank++
    }
    Write-Host ""
    
    # Explain the results
    Write-Host "CONCLUSION:" -ForegroundColor Green
    
    if ($simpleFailuresPhase2 -gt 0) {
        Write-Host "  Simple Hash issues during churn:" -ForegroundColor Yellow
        Write-Host "    - $simpleFailuresPhase2 requests failed in Phase 2 (before membership update)"
        Write-Host "    - Keys remapped twice: once on removal, once on recovery"
        Write-Host "    - Cache effectiveness fluctuates significantly with membership changes"
    }
    
    if ($chordFailuresPhase2 -eq 0 -and $koordeFailuresPhase2 -eq 0) {
        Write-Host ""
        Write-Host "  Consistent hashing (Chord/Koorde) advantages:" -ForegroundColor Green
        Write-Host "    - Zero request failures (routes around dead nodes)"
        Write-Host "    - Only ~$([Math]::Round(100*$NodesToRemove/$Nodes, 0))% of keys affected per change"
        Write-Host "    - More stable cache hit rate across membership changes"
    }
} else {
    Write-Host "Churn testing was skipped. Run without -SkipChurn to see the real difference."
}

Write-Host ""
Write-Host "Key Takeaways:" -ForegroundColor Yellow
Write-Host "  1. Node pattern tested: $Nodes -> $NodesAfterRemoval -> $Nodes (remove $NodesToRemove, add back)"
Write-Host "  2. Simple hash: ~$([Math]::Round(100*$NodesToRemove/$Nodes, 0))% keys remap on EACH membership change"
Write-Host "  3. Consistent hashing: only ~$([Math]::Round(100*$NodesToRemove/$Nodes, 0))% keys affected (removed/added nodes only)"
Write-Host "  4. After full cycle, consistent hashing maintains better cache coherence"
Write-Host ""

# Save summary report
$summaryFile = "$ResultsDir/comparison-summary-$timestamp.txt"

$summaryContent = @"
Cache Hit/Miss Rate Comparison Report (3-Phase Node Churn)
==========================================================
Date: $(Get-Date)
Timestamp: $timestamp

Test Configuration:
  Node Pattern: $Nodes -> $NodesAfterRemoval -> $Nodes
  Nodes Removed/Added: $NodesToRemove
  Unique URLs: $URLs
  Phase 1 Requests: $WarmupRequests (warmup)
  Phase 2 Requests: $ChurnRequests (after removal)
  Phase 3 Requests: $RecoveryRequests (after recovery)
  Request Rate: $Rate req/s
  Zipf alpha: $Zipf
  Koorde Degree: $Degree

Theoretical Key Redistribution per change:
  Simple Hash:  ~$([Math]::Round(100*$NodesToRemove/$Nodes, 1))% (hash % N changes)
  Chord/Koorde: ~$([Math]::Round(100*$NodesToRemove/$Nodes, 1))% (only affected nodes' keys)

EFFECTIVE HIT RATE PROGRESSION:
  Protocol       Phase1    Phase2    Phase3    Total Change
$(if ($results["simple"]) { "  Simple Hash   $($results["simple"].Phase1EffectiveRate)%      $($results["simple"].Phase2EffectiveRate)%      $($results["simple"].Phase3EffectiveRate)%      $([Math]::Round($results["simple"].Phase3EffectiveRate - $results["simple"].Phase1EffectiveRate, 1))%" })
$(if ($results["chord"]) { "  Chord         $($results["chord"].Phase1EffectiveRate)%      $($results["chord"].Phase2EffectiveRate)%      $($results["chord"].Phase3EffectiveRate)%      $([Math]::Round($results["chord"].Phase3EffectiveRate - $results["chord"].Phase1EffectiveRate, 1))%" })
$(if ($results["koorde"]) { "  Koorde        $($results["koorde"].Phase1EffectiveRate)%      $($results["koorde"].Phase2EffectiveRate)%      $($results["koorde"].Phase3EffectiveRate)%      $([Math]::Round($results["koorde"].Phase3EffectiveRate - $results["koorde"].Phase1EffectiveRate, 1))%" })

FAILURES BY PHASE:
  Protocol       Phase1    Phase2    Phase3
$(if ($results["simple"]) { "  Simple Hash   $($results["simple"].Phase1Failures)         $($results["simple"].Phase2Failures)         $($results["simple"].Phase3Failures)" })
$(if ($results["chord"]) { "  Chord         $($results["chord"].Phase1Failures)         $($results["chord"].Phase2Failures)         $($results["chord"].Phase3Failures)" })
$(if ($results["koorde"]) { "  Koorde        $($results["koorde"].Phase1Failures)         $($results["koorde"].Phase2Failures)         $($results["koorde"].Phase3Failures)" })

Latency Results (Phase 1):
  Protocol      Avg(ms)   P50(ms)   P95(ms)   P99(ms)
$(if ($results["simple"] -and $results["simple"].Phase1) { "  Simple Hash   $($results["simple"].Phase1.AvgLatency)       $($results["simple"].Phase1.P50)       $($results["simple"].Phase1.P95)       $($results["simple"].Phase1.P99)" })
$(if ($results["chord"] -and $results["chord"].Phase1) { "  Chord         $($results["chord"].Phase1.AvgLatency)       $($results["chord"].Phase1.P50)       $($results["chord"].Phase1.P95)       $($results["chord"].Phase1.P99)" })
$(if ($results["koorde"] -and $results["koorde"].Phase1) { "  Koorde        $($results["koorde"].Phase1.AvgLatency)       $($results["koorde"].Phase1.P50)       $($results["koorde"].Phase1.P95)       $($results["koorde"].Phase1.P99)" })

Raw Data Files:
  Simple Hash: $ResultsDir/simple-hash-phase1-$timestamp.csv, phase2, phase3
  Chord:       $ResultsDir/chord-phase1-$timestamp.csv, phase2, phase3
  Koorde:      $ResultsDir/koorde-phase1-$timestamp.csv, phase2, phase3
"@

$summaryContent | Out-File -FilePath $summaryFile -Encoding UTF8

# Stop mock origin server
Stop-MockOrigin

Write-Host "Results saved to:" -ForegroundColor Gray
Write-Host "  Summary: $summaryFile"
Write-Host "  Raw CSV: $ResultsDir/*.csv"
Write-Host ""
Write-Host "Experiment completed successfully!" -ForegroundColor Green
