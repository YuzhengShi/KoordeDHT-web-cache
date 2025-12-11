#!/bin/bash
#
# Stop Locust Load Test on ECS
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

if [ ! -f "locust-config.env" ]; then
    echo "Error: locust-config.env not found."
    exit 1
fi

source locust-config.env

echo "Stopping all Locust tasks..."

# Get all running tasks
TASKS=$(aws ecs list-tasks \
    --cluster "$CLUSTER_NAME" \
    --query "taskArns" \
    --output text \
    --region "$REGION" 2>/dev/null || true)

if [ -n "$TASKS" ] && [ "$TASKS" != "None" ]; then
    for TASK in $TASKS; do
        echo "Stopping task: $TASK"
        aws ecs stop-task \
            --cluster "$CLUSTER_NAME" \
            --task "$TASK" \
            --region "$REGION" > /dev/null 2>&1 || true
    done
    echo "All tasks stopped."
else
    echo "No tasks running."
fi

