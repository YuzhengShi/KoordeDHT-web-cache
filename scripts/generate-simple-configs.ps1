# Generate Simple Hash cluster configuration files
# Usage: .\generate-simple-configs.ps1 -Nodes 8
#
# Simple hash uses modulo hashing (hash % N) for node selection.
# Unlike Chord/Koorde, all nodes must know the full cluster membership upfront.

param(
    [int]$Nodes = 8,
    [string]$OutputDir = "config/simple-cluster",
    [int]$SimulatedLatencyMs = 0  # 0 = no simulated latency (real network)
)

Write-Host "=== Generating Simple Hash Cluster Config ===" -ForegroundColor Green
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

# Build the full cluster nodes list (all nodes must know all other nodes)
$clusterNodesArray = @()
for ($i = 0; $i -lt $Nodes; $i++) {
    $clusterNodesArray += "`"localhost:$(4000 + $i)`""
}
$clusterNodesYaml = "[" + ($clusterNodesArray -join ", ") + "]"

Write-Host "Cluster nodes: $clusterNodesYaml"
Write-Host ""

# Generate config for each node
for ($i = 0; $i -lt $Nodes; $i++) {
    $grpcPort = 4000 + $i
    $httpPort = 8080 + $i
    
    # For simple hash, we don't use bootstrap peers in the traditional sense
    # All nodes know the full cluster via clusterNodes config
    $peersYaml = "[]"
    
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
  protocol: simple
  mode: private
  
  # Full cluster membership for simple hash routing
  clusterNodes: $clusterNodesYaml
  
  bootstrap:
    mode: static
    peers: $peersYaml
  
  # These settings are not used by simple hash but required for config validation
  deBruijn:
    degree: 2
    fixInterval: 5s
  
  faultTolerance:
    successorListSize: $([Math]::Min($Nodes, 8))
    stabilizationInterval: 10s
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
Write-Host "Simple hash configuration generated successfully!" -ForegroundColor Green
Write-Host ""
Write-Host "Routing characteristics:" -ForegroundColor Cyan
Write-Host "  Simple Hash: O(1) - direct lookup via hash(key) % N"
Write-Host "  Key redistribution on node change: ~100% (N-1)/N keys move"
Write-Host ""
Write-Host "Compare with consistent hashing (Chord/Koorde):" -ForegroundColor Yellow
Write-Host "  Key redistribution on node change: ~1/N keys move"
Write-Host ""


