#!/bin/bash

if [ -f logs/pids.txt ]; then
    PIDS=$(cat logs/pids.txt)
    echo "Stopping nodes with PIDs: $PIDS"
    kill $PIDS 2>/dev/null || true
    rm -f logs/pids.txt
    echo "All nodes stopped."
else
    echo "No running cluster found (logs/pids.txt not found)"
    echo "Trying to find and kill koorde-node processes..."
    pkill -f koorde-node || echo "No koorde-node processes found"
fi

