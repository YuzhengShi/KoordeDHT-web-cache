#!/bin/sh
# entrypoint.sh: Two-phase bootstrap for KoordeDHT StatefulSet

set -e

# Get pod ordinal from hostname (assumes StatefulSet pod naming: dht-node-0, dht-node-1, ...)
ORDINAL=$(echo "$HOSTNAME" | awk -F'-' '{print $NF}')


# Define the full list of bootstrap peers (update as needed for your cluster size)
# Use correct StatefulSet and headless service DNS and gRPC port (4000)
PEERS="dht-node-0.dht-headless.koorde-dht.svc.cluster.local:4000,dht-node-1.dht-headless.koorde-dht.svc.cluster.local:4000,dht-node-2.dht-headless.koorde-dht.svc.cluster.local:4000"

if [ "$ORDINAL" = "0" ]; then
  export BOOTSTRAP_PEERS=""
  echo "[entrypoint] This is node-0. Starting new DHT ring."
else
  export BOOTSTRAP_PEERS="$PEERS"
  echo "[entrypoint] This is node-$ORDINAL. Joining DHT ring via peers: $PEERS"
fi

# Launch the main process (replace with your actual CMD if different)
exec "$@"
