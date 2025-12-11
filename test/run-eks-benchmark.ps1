<#
.SYNOPSIS
    EKS Throughput Benchmark Script for Koorde vs Chord

.DESCRIPTION
    This script runs Locust load tests against both DHT protocols
    deployed on AWS EKS and generates comparison reports.

.PARAMETER KoordeUrl
    The load balancer URL for the Koorde deployment

.PARAMETER ChordUrl
    The load balancer URL for the Chord deployment

.PARAMETER Users
    Number of concurrent users (default: 100)

.PARAMETER SpawnRate
    Users to spawn per second (default: 10)

.PARAMETER Duration
    Test duration (default: 5m)

.PARAMETER UrlPoolSize
    URL pool size for testing (default: 500)

.PARAMETER ZipfAlpha
    Zipf distribution skew factor (default: 1.2)

.EXAMPLE
    .\run-eks-benchmark.ps1 `
        -KoordeUrl "http://koorde-lb.amazonaws.com" `
        -ChordUrl "http://chord-lb.amazonaws.com" `
        -Users 100 -Duration "5m"
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$KoordeUrl,
    
    [Parameter(Mandatory=$true)]
    [string]$ChordUrl,
    
    [int]$Users = 100,
    [int]$SpawnRate = 10,
    [string]$Duration = "5m",
    [int]$UrlPoolSize = 500,
    [double]$ZipfAlpha = 1.2,
    [string]$OutputDir = "benchmark-results"
)

$ErrorActionPreference = "Stop"

# Create result directory
$Timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$ResultDir = Join-Path $OutputDir $Timestamp
New-Item -ItemType Directory -Path $ResultDir -Force | Out-Null

Write-Host ""
Write-Host "============================================" -ForegroundColor Blue
Write-Host " DHT Protocol Throughput Benchmark" -ForegroundColor Blue
Write-Host "============================================" -ForegroundColor Blue
Write-Host ""
Write-Host "Configuration:" -ForegroundColor Green
Write-Host "  Koorde URL:    $KoordeUrl"
Write-Host "  Chord URL:     $ChordUrl"
Write-Host "  Users:         $Users"
Write-Host "  Spawn Rate:    $SpawnRate/sec"
Write-Host "  Duration:      $Duration"
Write-Host "  URL Pool:      $UrlPoolSize"
Write-Host "  Zipf Alpha:    $ZipfAlpha"
Write-Host "  Output Dir:    $ResultDir"
Write-Host ""

# Health check function
function Test-ClusterHealth {
    param([string]$Url, [string]$Name)
    
    Write-Host -NoNewline "Checking $Name health... "
    try {
        $response = Invoke-RestMethod -Uri "$Url/health" -TimeoutSec 10 -ErrorAction Stop
        if ($response.healthy -or $response -match "healthy") {
            Write-Host "OK" -ForegroundColor Green
            return $true
        }
    } catch {
        # Ignore
    }
    Write-Host "FAILED" -ForegroundColor Red
    return $false
}

# Pre-flight health checks
Write-Host "Running health checks..." -ForegroundColor Yellow
if (-not (Test-ClusterHealth -Url $KoordeUrl -Name "Koorde")) {
    Write-Host "Koorde cluster is not healthy. Aborting." -ForegroundColor Red
    exit 1
}

if (-not (Test-ClusterHealth -Url $ChordUrl -Name "Chord")) {
    Write-Host "Chord cluster is not healthy. Aborting." -ForegroundColor Red
    exit 1
}

Write-Host ""

# Run test function
function Invoke-LocustTest {
    param(
        [string]$Protocol,
        [string]$Url
    )
    
    $CsvPrefix = Join-Path $ResultDir $Protocol
    
    Write-Host ""
    Write-Host "============================================" -ForegroundColor Blue
    Write-Host " Testing $($Protocol.ToUpper()) Protocol" -ForegroundColor Blue
    Write-Host "============================================" -ForegroundColor Blue
    Write-Host "URL: $Url"
    Write-Host ""
    
    # Set environment variables
    $env:PROTOCOL = $Protocol
    $env:URL_POOL_SIZE = $UrlPoolSize
    $env:ZIPF_ALPHA = $ZipfAlpha
    
    # Run locust
    $locustArgs = @(
        "-f", "locustfile.py"
        "--host", $Url
        "--users", $Users
        "--spawn-rate", $SpawnRate
        "--run-time", $Duration
        "--headless"
        "--csv", $CsvPrefix
        "--html", "$CsvPrefix-report.html"
    )
    
    $outputLog = "$CsvPrefix-output.log"
    
    locust @locustArgs 2>&1 | Tee-Object -FilePath $outputLog
    
    # Move JSON results
    Get-ChildItem -Path "." -Filter "locust-results-$Protocol-*.json" -ErrorAction SilentlyContinue | 
        Move-Item -Destination $ResultDir -Force
}

# Run tests
Write-Host "Starting Koorde benchmark..." -ForegroundColor Yellow
Invoke-LocustTest -Protocol "koorde" -Url $KoordeUrl

Write-Host ""
Write-Host "Waiting 30 seconds before next test..." -ForegroundColor Yellow
Start-Sleep -Seconds 30

Write-Host "Starting Chord benchmark..." -ForegroundColor Yellow
Invoke-LocustTest -Protocol "chord" -Url $ChordUrl

# Generate comparison summary
Write-Host ""
Write-Host "============================================" -ForegroundColor Blue
Write-Host " Generating Comparison Summary" -ForegroundColor Blue
Write-Host "============================================" -ForegroundColor Blue

$SummaryFile = Join-Path $ResultDir "comparison-summary.txt"

$summary = @"
DHT Protocol Throughput Comparison
==================================
Date: $(Get-Date)
Duration: $Duration
Users: $Users
Spawn Rate: $SpawnRate/sec
URL Pool Size: $UrlPoolSize
Zipf Alpha: $ZipfAlpha

Koorde URL: $KoordeUrl
Chord URL: $ChordUrl

Results:
--------
"@

foreach ($protocol in @("koorde", "chord")) {
    $jsonFiles = Get-ChildItem -Path $ResultDir -Filter "locust-results-$protocol-*.json" -ErrorAction SilentlyContinue
    if ($jsonFiles) {
        $jsonFile = $jsonFiles[0].FullName
        $data = Get-Content $jsonFile | ConvertFrom-Json
        
        $summary += @"

$($protocol.ToUpper()):
  Throughput: $($data.throughput_rps) req/sec
  Avg Latency: $($data.avg_latency_ms) ms
  Hit Rate: $($data.hit_rate)%
  Total Requests: $($data.total_requests)
  Errors: $($data.errors)
"@
    }
}

$summary | Out-File -FilePath $SummaryFile -Encoding utf8
Write-Host $summary

Write-Host ""
Write-Host "============================================" -ForegroundColor Green
Write-Host " Benchmark Complete!" -ForegroundColor Green
Write-Host "============================================" -ForegroundColor Green
Write-Host ""
Write-Host "Results saved to: $ResultDir"
Write-Host "  - $ResultDir\koorde-report.html"
Write-Host "  - $ResultDir\chord-report.html"
Write-Host "  - $ResultDir\comparison-summary.txt"
Write-Host ""

