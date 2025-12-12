param(
    [int]$NodeCount = 3,
    [int]$BaseGrpcPort = 4000,
    [int]$BaseHttpPort = 8080,
    [string]$ConfigDir = "config/local-cluster",
    [string]$BinaryPath = "bin/koorde-node",
    [switch]$SkipBuild,
    [string]$BenchmarkCommand = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Stop-KoordeCluster {
    # Kill by process name first (more reliable)
    Get-Process -Name "koorde-node" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    
    # Also try PIDs from file as backup
    if (Test-Path "logs/pids.txt") {
        $pids = Get-Content "logs/pids.txt" | Where-Object { $_ -match '^[0-9]+$' }
        foreach ($pid in $pids) {
            try {
                Stop-Process -Id [int]$pid -Force -ErrorAction SilentlyContinue
            } catch {
                # Ignore - process may already be dead
            }
        }
        Remove-Item "logs/pids.txt" -Force -ErrorAction SilentlyContinue
    }
    
    # Brief pause to let ports release
    Start-Sleep -Seconds 2
}

function Start-KoordeNode {
    param(
        [int]$Index
    )

    $configPath = Join-Path $ConfigDir "node$Index.yaml"
    if (-not (Test-Path $configPath)) {
        throw "Config file not found: $configPath"
    }

    $stdoutPath = "logs/node$Index.stdout.log"
    $stderrPath = "logs/node$Index.stderr.log"
    $arguments = "--config `"$configPath`""

    Write-Host "Starting node $Index (config: $configPath)" -ForegroundColor Cyan
    $process = Start-Process -FilePath $BinaryPath -ArgumentList $arguments `
        -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -PassThru
    return $process.Id
}

function Wait-NodeReady {
    param(
        [int]$HttpPort,
        [int]$TimeoutSeconds = 120
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        try {
            $resp = Invoke-RestMethod -Uri "http://localhost:$HttpPort/health" -TimeoutSec 3
            Write-Host ("Port {0}: {1}" -f $HttpPort, $resp.status)
            if ($resp.status -eq "READY") {
                return
            }
        } catch {
            $handled = $false
            if ($_.Exception.Response) {
                try {
                    $stream = $_.Exception.Response.GetResponseStream()
                    if ($stream) {
                        $reader = New-Object System.IO.StreamReader($stream)
                        $body = $reader.ReadToEnd()
                        $reader.Close()
                        if ($body) {
                            $json = $body | ConvertFrom-Json -ErrorAction Stop
                            if ($json.status) {
                                Write-Host ("Port {0}: {1}" -f $HttpPort, $json.status)
                                $handled = $true
                                if ($json.status -eq "READY") {
                                    return
                                }
                            }
                        }
                    }
                } catch {
                    # ignore parsing issues, fall back to waiting message
                }
            }

            if (-not $handled) {
                Write-Host ("Port {0}: waiting for HTTP endpoint..." -f $HttpPort)
            }
        }
        Start-Sleep -Seconds 1
    } while ((Get-Date) -lt $deadline)

    throw "Node on HTTP port $HttpPort did not become READY before timeout"
}

if (-not $SkipBuild) {
    Write-Host "Building koorde node binary..." -ForegroundColor Yellow
    go build -o $BinaryPath ./cmd/node
}

Stop-KoordeCluster

if (-not (Test-Path "logs")) {
    New-Item -ItemType Directory -Path "logs" | Out-Null
}

$startedPids = @()
for ($i = 0; $i -lt $NodeCount; $i++) {
    $startedPids += Start-KoordeNode -Index $i
    Start-Sleep -Seconds 2
}

$startedPids -join ' ' | Set-Content "logs/pids.txt"

for ($i = 0; $i -lt $NodeCount; $i++) {
    $httpPort = $BaseHttpPort + $i
    Wait-NodeReady -HttpPort $httpPort
}

Write-Host "All nodes are READY." -ForegroundColor Green

if ($BenchmarkCommand -and ($BenchmarkCommand.Trim().Length -gt 0)) {
    Write-Host "Running benchmark command: $BenchmarkCommand" -ForegroundColor Yellow
    Invoke-Expression $BenchmarkCommand
}
