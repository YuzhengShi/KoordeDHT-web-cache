#!/bin/bash
#
# EKS Throughput Benchmark Script for Koorde vs Chord
#
# This script runs Locust load tests against both DHT protocols
# deployed on AWS EKS and generates comparison reports.
#
# Usage:
#   ./run-eks-benchmark.sh <koorde-lb-url> <chord-lb-url> [options]
#
# Example:
#   ./run-eks-benchmark.sh \
#     "http://a1b2c3d4.us-west-2.elb.amazonaws.com" \
#     "http://e5f6g7h8.us-west-2.elb.amazonaws.com" \
#     --users 100 --duration 5m
#

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default configuration
USERS=100
SPAWN_RATE=10
DURATION="5m"
URL_POOL_SIZE=500
ZIPF_ALPHA=1.2
OUTPUT_DIR="benchmark-results"

# Parse arguments
KOORDE_URL=""
CHORD_URL=""

usage() {
    echo "Usage: $0 <koorde-lb-url> <chord-lb-url> [options]"
    echo ""
    echo "Options:"
    echo "  --users N        Number of concurrent users (default: $USERS)"
    echo "  --spawn-rate N   Users to spawn per second (default: $SPAWN_RATE)"
    echo "  --duration T     Test duration (default: $DURATION)"
    echo "  --url-pool N     URL pool size (default: $URL_POOL_SIZE)"
    echo "  --zipf-alpha N   Zipf distribution alpha (default: $ZIPF_ALPHA)"
    echo "  --output-dir D   Output directory (default: $OUTPUT_DIR)"
    echo ""
    echo "Example:"
    echo "  $0 http://koorde-lb.amazonaws.com http://chord-lb.amazonaws.com --users 200"
    exit 1
}

# Parse command line arguments
if [ $# -lt 2 ]; then
    usage
fi

KOORDE_URL="$1"
CHORD_URL="$2"
shift 2

while [[ $# -gt 0 ]]; do
    case $1 in
        --users)
            USERS="$2"
            shift 2
            ;;
        --spawn-rate)
            SPAWN_RATE="$2"
            shift 2
            ;;
        --duration)
            DURATION="$2"
            shift 2
            ;;
        --url-pool)
            URL_POOL_SIZE="$2"
            shift 2
            ;;
        --zipf-alpha)
            ZIPF_ALPHA="$2"
            shift 2
            ;;
        --output-dir)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            usage
            ;;
    esac
done

# Create output directory
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
RESULT_DIR="${OUTPUT_DIR}/${TIMESTAMP}"
mkdir -p "$RESULT_DIR"

echo -e "${BLUE}============================================${NC}"
echo -e "${BLUE} DHT Protocol Throughput Benchmark${NC}"
echo -e "${BLUE}============================================${NC}"
echo ""
echo -e "${GREEN}Configuration:${NC}"
echo "  Koorde URL:    $KOORDE_URL"
echo "  Chord URL:     $CHORD_URL"
echo "  Users:         $USERS"
echo "  Spawn Rate:    $SPAWN_RATE/sec"
echo "  Duration:      $DURATION"
echo "  URL Pool:      $URL_POOL_SIZE"
echo "  Zipf Alpha:    $ZIPF_ALPHA"
echo "  Output Dir:    $RESULT_DIR"
echo ""

# Health check function
check_health() {
    local url="$1"
    local name="$2"
    
    echo -n "Checking $name health... "
    if curl -s --max-time 10 "${url}/health" | grep -q "healthy"; then
        echo -e "${GREEN}OK${NC}"
        return 0
    else
        echo -e "${RED}FAILED${NC}"
        return 1
    fi
}

# Pre-flight health checks
echo -e "${YELLOW}Running health checks...${NC}"
if ! check_health "$KOORDE_URL" "Koorde"; then
    echo -e "${RED}Koorde cluster is not healthy. Aborting.${NC}"
    exit 1
fi

if ! check_health "$CHORD_URL" "Chord"; then
    echo -e "${RED}Chord cluster is not healthy. Aborting.${NC}"
    exit 1
fi

echo ""

# Run test function
run_test() {
    local protocol="$1"
    local url="$2"
    local csv_prefix="${RESULT_DIR}/${protocol}"
    
    echo -e "${BLUE}============================================${NC}"
    echo -e "${BLUE} Testing ${protocol^^} Protocol${NC}"
    echo -e "${BLUE}============================================${NC}"
    echo "URL: $url"
    echo ""
    
    export PROTOCOL="$protocol"
    export URL_POOL_SIZE="$URL_POOL_SIZE"
    export ZIPF_ALPHA="$ZIPF_ALPHA"
    
    locust \
        -f locustfile.py \
        --host "$url" \
        --users "$USERS" \
        --spawn-rate "$SPAWN_RATE" \
        --run-time "$DURATION" \
        --headless \
        --csv "$csv_prefix" \
        --html "${csv_prefix}-report.html" \
        2>&1 | tee "${csv_prefix}-output.log"
    
    # Move JSON results to result directory
    if ls locust-results-${protocol}-*.json 1> /dev/null 2>&1; then
        mv locust-results-${protocol}-*.json "$RESULT_DIR/"
    fi
    
    echo ""
}

# Run tests
echo -e "${YELLOW}Starting Koorde benchmark...${NC}"
run_test "koorde" "$KOORDE_URL"

echo -e "${YELLOW}Waiting 30 seconds before next test...${NC}"
sleep 30

echo -e "${YELLOW}Starting Chord benchmark...${NC}"
run_test "chord" "$CHORD_URL"

# Generate comparison summary
echo -e "${BLUE}============================================${NC}"
echo -e "${BLUE} Generating Comparison Summary${NC}"
echo -e "${BLUE}============================================${NC}"

SUMMARY_FILE="${RESULT_DIR}/comparison-summary.txt"

cat > "$SUMMARY_FILE" << EOF
DHT Protocol Throughput Comparison
==================================
Date: $(date)
Duration: $DURATION
Users: $USERS
Spawn Rate: $SPAWN_RATE/sec
URL Pool Size: $URL_POOL_SIZE
Zipf Alpha: $ZIPF_ALPHA

Koorde URL: $KOORDE_URL
Chord URL: $CHORD_URL

Results:
--------
EOF

# Parse and compare results
for protocol in koorde chord; do
    json_file=$(ls "${RESULT_DIR}/locust-results-${protocol}-"*.json 2>/dev/null | head -1)
    if [ -f "$json_file" ]; then
        echo "" >> "$SUMMARY_FILE"
        echo "${protocol^^}:" >> "$SUMMARY_FILE"
        echo "  Throughput: $(jq -r '.throughput_rps' "$json_file") req/sec" >> "$SUMMARY_FILE"
        echo "  Avg Latency: $(jq -r '.avg_latency_ms' "$json_file") ms" >> "$SUMMARY_FILE"
        echo "  Hit Rate: $(jq -r '.hit_rate' "$json_file")%" >> "$SUMMARY_FILE"
        echo "  Total Requests: $(jq -r '.total_requests' "$json_file")" >> "$SUMMARY_FILE"
        echo "  Errors: $(jq -r '.errors' "$json_file")" >> "$SUMMARY_FILE"
    fi
done

cat "$SUMMARY_FILE"

echo ""
echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN} Benchmark Complete!${NC}"
echo -e "${GREEN}============================================${NC}"
echo ""
echo "Results saved to: $RESULT_DIR"
echo "  - ${RESULT_DIR}/koorde-report.html"
echo "  - ${RESULT_DIR}/chord-report.html"
echo "  - ${RESULT_DIR}/comparison-summary.txt"
echo ""

