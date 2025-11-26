# Generate Chord cluster configuration files
# Usage: .\generate-chord-configs.ps1 -Nodes 8

param(
    [int]$Nodes = 8,
    [string]$OutputDir = "config/chord-cluster",
    [int]$SimulatedLatencyMs = 0  # 0 = no simulated latency (real network)
)

Write-Host "=== Generating Chord Cluster Config ===" -ForegroundColor Green
Write-Host "Nodes:  $Nodes"
Write-Host "Output: $OutputDir"

# Simulated latency configuration
if ($SimulatedLatencyMs -gt 0) {
    $simulatedLatencyStr = "$($SimulatedLatencyMs)ms"
    Write-Host "Simulated Latency: $simulatedLatencyStr per hop" -ForegroundColor Yellow
} else {
    $simulatedLatencyStr = "0ms"
    Write-Host "Simulated Latency: disabled (real network)"
}
Write-Host ""

# Create output directory
if (Test-Path $OutputDir) {
    Remove-Item -Recurse -Force $OutputDir
}
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null

# Generate config for each node
for ($i = 0; $i -lt $Nodes; $i++) {
    $grpcPort = 4000 + $i
    $httpPort = 8080 + $i
    
    # First node has no bootstrap peers, others bootstrap from node0
    if ($i -eq 0) {
        $peersYaml = "[]"
    } else {
        $peersYaml = "[`"localhost:4000`"]"
    }
    
    $config = @"
logger:
  active: true
  level: info
  encoding: console
  mode: stdout

node:
  bind: "0.0.0.0"
  host: "localhost"
  port: $grpcPort

dht:
  idBits: 66
  protocol: chord
  mode: private
  
  bootstrap:
    mode: static
    peers: $peersYaml
  
  deBruijn:
    degree: 2
    fixInterval: 5s
  
  faultTolerance:
    successorListSize: $([Math]::Min($Nodes, 8))
    stabilizationInterval: 2s
    failureTimeout: 1s
    simulatedLatency: $simulatedLatencyStr

  storage:
    fixInterval: 20s

cache:
  enabled: true
  httpPort: $httpPort
  capacityMB: 256
  defaultTTL: 3600
  hotspotThreshold: 10.0
  hotspotDecayRate: 0.65

telemetry:
  tracing:
    enabled: false
"@

    $configPath = "$OutputDir/node$i.yaml"
    $config | Out-File -FilePath $configPath -Encoding UTF8
    Write-Host "  Created: $configPath (gRPC: $grpcPort, HTTP: $httpPort)"
}

Write-Host ""
Write-Host "Chord configuration generated successfully!" -ForegroundColor Green
Write-Host ""
$m = [Math]::Ceiling([Math]::Log($Nodes) / [Math]::Log(2))
Write-Host "Theoretical Chord routing: O(log n) = ~$m hops" -ForegroundColor Cyan
Write-Host ""
