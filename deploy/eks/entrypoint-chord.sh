#!/bin/bash
set -euo pipefail

# Chord-specific entrypoint for Kubernetes
# This script sets up the correct bootstrap peers for Chord in the chord-dht namespace.

NAMESPACE="chord-dht"
STATEFULSET_NAME="dht-node"
HEADLESS_SERVICE="dht-headless"
REPLICAS="${REPLICAS:-3}"
PORT="4000"

# Generate bootstrap peer list (first 3 pods by default)
PEERS=""
for i in 0 1 2; do
  PEERS+="${STATEFULSET_NAME}-${i}.${HEADLESS_SERVICE}.${NAMESPACE}.svc.cluster.local:${PORT},"
done
# Remove trailing comma
PEERS=${PEERS%,}

export BOOTSTRAP_PEERS="$PEERS"
echo "[entrypoint-chord.sh] BOOTSTRAP_PEERS set to: $BOOTSTRAP_PEERS"

# Start the Chord node (replace with your actual start command)
exec "$@"
