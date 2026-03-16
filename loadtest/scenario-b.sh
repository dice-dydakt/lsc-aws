#!/bin/bash
# Scenario B: Warm Steady-State Throughput
# Run AFTER warming up all targets
#
# Usage: ./scenario-b.sh <lambda-zip-url> <lambda-container-url> <fargate-alb-url> <ec2-url>
# Example: ./scenario-b.sh https://abc.lambda-url.us-east-1.on.aws https://def.lambda-url.us-east-1.on.aws http://alb-dns-name http://1.2.3.4:8080

set -euo pipefail

LAMBDA_ZIP_URL="${1:?Usage: $0 <lambda-zip-url> <lambda-container-url> <fargate-alb-url> <ec2-url>}"
LAMBDA_CONTAINER_URL="${2:?}"
FARGATE_URL="${3:?}"
EC2_URL="${4:?}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
QUERY=$(cat "${SCRIPT_DIR}/query.json")
RESULTS_DIR="${SCRIPT_DIR}/../results"
mkdir -p "$RESULTS_DIR"

declare -a NAMES=("lambda-zip" "lambda-container" "fargate" "ec2")
declare -a URLS=("${LAMBDA_ZIP_URL}/search" "${LAMBDA_CONTAINER_URL}/search" "${FARGATE_URL}/search" "${EC2_URL}/search")

echo "=== Scenario B: Warm Steady-State Throughput ==="

# Warm-up all targets
echo "--- Warm-up phase ---"
for i in "${!URLS[@]}"; do
    echo "  Warming up ${NAMES[$i]}..."
    hey -n 20 -c 5 -m POST \
        -H "Content-Type: application/json" \
        -d "$QUERY" \
        "${URLS[$i]}" > /dev/null 2>&1
done
echo "Warm-up complete."
echo ""

# Run measurements
for i in "${!URLS[@]}"; do
    for CONC in 10 50; do
        OUTFILE="${RESULTS_DIR}/scenario-b-${NAMES[$i]}-c${CONC}.txt"
        echo "=== ${NAMES[$i]} | concurrency=${CONC} | 500 requests ===" | tee "$OUTFILE"
        hey -n 500 -c "$CONC" -m POST \
            -H "Content-Type: application/json" \
            -d "$QUERY" \
            "${URLS[$i]}" 2>&1 | tee -a "$OUTFILE"
        echo "" | tee -a "$OUTFILE"
        sleep 5
    done
done

echo "=== Scenario B complete. Results in ${RESULTS_DIR} ==="
