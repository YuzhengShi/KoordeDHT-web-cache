# Generate cluster configuration files for testing different node counts and de Bruijn degrees
# Usage: .\generate-cluster-configs.ps1 -Nodes 8 -Degree 3

param(
    [int]$Nodes = 8,
    [int]$Degree = 3,
    [string]$OutputDir = "config/test-cluster"
)

Write-Host "=== Generating Koorde Cluster Config ===" -ForegroundColor Green
Write-Host "Nodes:  $Nodes"
Write-Host "Degree: $Degree"
Write-Host "Output: $OutputDir"
Write-Host ""

# Create output directory
if (Test-Path $OutputDir) {
    Remove-Item -Recurse -Force $OutputDir
}
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null

# Generate bootstrap peers list (all nodes except the first one will use node0 as bootstrap)
$bootstrapPeers = @()
for ($i = 0; $i -lt $Nodes; $i++) {
    $bootstrapPeers += "localhost:$(4000 + $i)"
}

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
  level: "info"
  encoding: "console"
  mode: "stdout"

node:
  bind: "0.0.0.0"
  host: "localhost"
  port: $grpcPort

dht:
  idBits: 66
  mode: "private"
  
  bootstrap:
    mode: "static"
    peers: $peersYaml
  
  deBruijn:
    degree: $Degree
    fixInterval: 3s
  
  storage:
    fixInterval: 20s
  
  faultTolerance:
    successorListSize: $([Math]::Min($Nodes, 8))
    stabilizationInterval: 2s
    failureTimeout: 1s

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
Write-Host "Configuration generated successfully!" -ForegroundColor Green
Write-Host ""
Write-Host "Theoretical de Bruijn routing:" -ForegroundColor Cyan
$m = [Math]::Ceiling([Math]::Log($Nodes) / [Math]::Log(2))
$logD = [Math]::Log($Degree) / [Math]::Log(2)
$chordHops = $m
$koordeHops = [Math]::Ceiling($m / $logD)
Write-Host "  Chord (O(log n)):           ~$chordHops hops"
Write-Host "  Koorde (O(log n / log d)):  ~$koordeHops hops"
Write-Host ""
