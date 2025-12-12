<#
.SYNOPSIS
    Compares Chord vs Koorde performance during membership churn.
    Runs the full churn test for both protocols and generates comparison report.

.PARAMETER InitialNodes
    Number of nodes to start with (default: 16)

.PARAMETER NodesToAdd
    Number of nodes to add during test (default: 8)

.PARAMETER NodesToRemove
    Number of nodes to remove during test (default: 4)

.EXAMPLE
    .\compare-churn-performance.ps1 -InitialNodes 16 -NodesToAdd 8 -NodesToRemove 4
#>

param(
    [int]$InitialNodes = 16,
    [int]$NodesToAdd = 8,
    [int]$NodesToRemove = 4,
    [int]$Degree = 4
)

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RootDir = Split-Path -Parent $ScriptDir

Write-Host ""
Write-Host "╔═══════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║     CHORD vs KOORDE: MEMBERSHIP CHURN COMPARISON          ║" -ForegroundColor Cyan
Write-Host "╠═══════════════════════════════════════════════════════════╣" -ForegroundColor Cyan
Write-Host "║  Initial Nodes:    $InitialNodes                                       ║" -ForegroundColor Cyan
Write-Host "║  Nodes to Add:     $NodesToAdd                                        ║" -ForegroundColor Cyan
Write-Host "║  Nodes to Remove:  $NodesToRemove                                        ║" -ForegroundColor Cyan
Write-Host "║  Koorde Degree:    $Degree                                        ║" -ForegroundColor Cyan
Write-Host "╚═══════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

# Run Chord test
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Yellow
Write-Host "  PHASE 1: Testing CHORD Protocol" -ForegroundColor Yellow
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Yellow
Write-Host ""

& "$ScriptDir\test-membership-churn.ps1" `
    -Protocol chord `
    -InitialNodes $InitialNodes `
    -NodesToAdd $NodesToAdd `
    -NodesToRemove $NodesToRemove `
    -Degree $Degree

# Stop cluster before switching
Push-Location "$RootDir\deploy\localstack"
docker-compose down 2>&1 | Out-Null
Pop-Location

Start-Sleep -Seconds 10

# Run Koorde test
Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Green
Write-Host "  PHASE 2: Testing KOORDE Protocol" -ForegroundColor Green
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Green
Write-Host ""

& "$ScriptDir\test-membership-churn.ps1" `
    -Protocol koorde `
    -InitialNodes $InitialNodes `
    -NodesToAdd $NodesToAdd `
    -NodesToRemove $NodesToRemove `
    -Degree $Degree

# Load results and compare
$chordResults = Import-Csv "$RootDir\churn-results-chord.csv"
$koordeResults = Import-Csv "$RootDir\churn-results-koorde.csv"

Write-Host ""
Write-Host "╔═══════════════════════════════════════════════════════════════════════════════╗" -ForegroundColor Magenta
Write-Host "║                      COMPARISON RESULTS                                       ║" -ForegroundColor Magenta
Write-Host "╚═══════════════════════════════════════════════════════════════════════════════╝" -ForegroundColor Magenta
Write-Host ""

# Stabilization comparison
Write-Host "┌─────────────────────────────────────────────────────────────────────────────┐" -ForegroundColor White
Write-Host "│  STABILIZATION TIME (lower is better)                                       │" -ForegroundColor White
Write-Host "├─────────────────────────────────────────────────────────────────────────────┤" -ForegroundColor White

$chordAddStab = ($chordResults | Where-Object { $_.Phase -eq "Stabilization-Add" }).Duration_s
$koordeAddStab = ($koordeResults | Where-Object { $_.Phase -eq "Stabilization-Add" }).Duration_s
$chordRemStab = ($chordResults | Where-Object { $_.Phase -eq "Stabilization-Remove" }).Duration_s
$koordeRemStab = ($koordeResults | Where-Object { $_.Phase -eq "Stabilization-Remove" }).Duration_s

$addWinner = if ([double]$koordeAddStab -lt [double]$chordAddStab) { "KOORDE ✓" } else { "CHORD ✓" }
$remWinner = if ([double]$koordeRemStab -lt [double]$chordRemStab) { "KOORDE ✓" } else { "CHORD ✓" }

Write-Host "│  After Adding Nodes:                                                        │" -ForegroundColor White
Write-Host "│    Chord:  ${chordAddStab}s    Koorde: ${koordeAddStab}s    Winner: $addWinner" -ForegroundColor $(if ($addWinner -like "*KOORDE*") { "Green" } else { "Yellow" })
Write-Host "│  After Removing Nodes:                                                      │" -ForegroundColor White
Write-Host "│    Chord:  ${chordRemStab}s    Koorde: ${koordeRemStab}s    Winner: $remWinner" -ForegroundColor $(if ($remWinner -like "*KOORDE*") { "Green" } else { "Yellow" })
Write-Host "└─────────────────────────────────────────────────────────────────────────────┘" -ForegroundColor White
Write-Host ""

# Latency comparison
Write-Host "┌─────────────────────────────────────────────────────────────────────────────┐" -ForegroundColor White
Write-Host "│  ROUTING LATENCY - P50 (lower is better)                                    │" -ForegroundColor White
Write-Host "├─────────────────────────────────────────────────────────────────────────────┤" -ForegroundColor White

$phases = @("Baseline-Warm", "After-Add-Warm", "After-Remove-Warm")
foreach ($phase in $phases) {
    $chordP50 = ($chordResults | Where-Object { $_.Phase -eq $phase }).P50_ms
    $koordeP50 = ($koordeResults | Where-Object { $_.Phase -eq $phase }).P50_ms
    $winner = if ([double]$koordeP50 -lt [double]$chordP50) { "KOORDE" } else { "CHORD" }
    $diff = [math]::Round(([double]$chordP50 - [double]$koordeP50), 2)
    
    Write-Host "│  $($phase.PadRight(20))  Chord: $($chordP50.ToString().PadRight(8))ms  Koorde: $($koordeP50.ToString().PadRight(8))ms  Δ: ${diff}ms" -ForegroundColor White
}
Write-Host "└─────────────────────────────────────────────────────────────────────────────┘" -ForegroundColor White
Write-Host ""

# Errors during churn
Write-Host "┌─────────────────────────────────────────────────────────────────────────────┐" -ForegroundColor White
Write-Host "│  ERRORS DURING CHURN (lower is better)                                      │" -ForegroundColor White
Write-Host "├─────────────────────────────────────────────────────────────────────────────┤" -ForegroundColor White

$chordAddErrors = ($chordResults | Where-Object { $_.Phase -eq "During-add" }).Errors
$koordeAddErrors = ($koordeResults | Where-Object { $_.Phase -eq "During-add" }).Errors
$chordRemErrors = ($chordResults | Where-Object { $_.Phase -eq "During-remove" }).Errors
$koordeRemErrors = ($koordeResults | Where-Object { $_.Phase -eq "During-remove" }).Errors

Write-Host "│  During Node Addition:    Chord: $chordAddErrors errors    Koorde: $koordeAddErrors errors" -ForegroundColor White
Write-Host "│  During Node Removal:     Chord: $chordRemErrors errors    Koorde: $koordeRemErrors errors" -ForegroundColor White
Write-Host "└─────────────────────────────────────────────────────────────────────────────┘" -ForegroundColor White
Write-Host ""

# Summary
$koordeWins = 0
$chordWins = 0

if ([double]$koordeAddStab -lt [double]$chordAddStab) { $koordeWins++ } else { $chordWins++ }
if ([double]$koordeRemStab -lt [double]$chordRemStab) { $koordeWins++ } else { $chordWins++ }

$chordP50Baseline = [double]($chordResults | Where-Object { $_.Phase -eq "Baseline-Warm" }).P50_ms
$koordeP50Baseline = [double]($koordeResults | Where-Object { $_.Phase -eq "Baseline-Warm" }).P50_ms
if ($koordeP50Baseline -lt $chordP50Baseline) { $koordeWins++ } else { $chordWins++ }

Write-Host "╔═══════════════════════════════════════════════════════════════════════════════╗" -ForegroundColor $(if ($koordeWins -gt $chordWins) { "Green" } else { "Yellow" })
Write-Host "║  OVERALL WINNER: $(if ($koordeWins -gt $chordWins) { 'KOORDE' } else { 'CHORD' }) ($koordeWins vs $chordWins categories)                                        ║" -ForegroundColor $(if ($koordeWins -gt $chordWins) { "Green" } else { "Yellow" })
Write-Host "╚═══════════════════════════════════════════════════════════════════════════════╝" -ForegroundColor $(if ($koordeWins -gt $chordWins) { "Green" } else { "Yellow" })
Write-Host ""

# Save combined report
$reportFile = "$RootDir\CHURN_COMPARISON_REPORT.md"
@"
# Chord vs Koorde: Membership Churn Comparison

**Test Configuration:**
- Initial Nodes: $InitialNodes
- Nodes Added: $NodesToAdd
- Nodes Removed: $NodesToRemove
- Koorde Degree: $Degree
- Test Date: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")

## Stabilization Time (seconds)

| Event | Chord | Koorde | Winner |
|-------|-------|--------|--------|
| After Adding $NodesToAdd Nodes | ${chordAddStab}s | ${koordeAddStab}s | $addWinner |
| After Removing $NodesToRemove Nodes | ${chordRemStab}s | ${koordeRemStab}s | $remWinner |

## Routing Latency (ms)

| Phase | Chord P50 | Koorde P50 | Difference |
|-------|-----------|------------|------------|
| Baseline (Warm) | $chordP50Baseline | $koordeP50Baseline | $([math]::Round($chordP50Baseline - $koordeP50Baseline, 2))ms |

## Errors During Churn

| Event | Chord Errors | Koorde Errors |
|-------|--------------|---------------|
| During Node Addition | $chordAddErrors | $koordeAddErrors |
| During Node Removal | $chordRemErrors | $koordeRemErrors |

## Analysis

**Why Koorde should perform better during churn:**
1. **Fewer routing table entries**: O(log N / log k) vs O(log N)
2. **Faster finger table updates**: Less state to synchronize
3. **De Bruijn resilience**: Topology naturally handles gaps

**Expected Results:**
- Koorde should stabilize faster after membership changes
- Koorde should have fewer routing errors during churn
- Koorde should show lower latency after stabilization
"@ | Out-File -FilePath $reportFile -Encoding UTF8

Write-Host "Full report saved to: $reportFile" -ForegroundColor Green
