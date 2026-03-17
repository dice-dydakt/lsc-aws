#!/bin/bash
# Scenario B: Warm Steady-State Throughput
# Run AFTER warming up all targets
#
# Uses hey for Fargate/EC2 and the Python SigV4 load tester for Lambda URLs.
#
# Usage: ./scenario-b.sh <lambda-zip-url> <lambda-container-url> <fargate-alb-url> <ec2-url>
# Example: ./scenario-b.sh https://abc.lambda-url.us-east-1.on.aws https://def.lambda-url.us-east-1.on.aws http://alb-dns-name http://1.2.3.4:8080

set -euo pipefail

LAMBDA_ZIP_URL="${1:?Usage: $0 <lambda-zip-url> <lambda-container-url> <fargate-alb-url> <ec2-url>}"
LAMBDA_CONTAINER_URL="${2:?}"
FARGATE_URL="${3:?}"
EC2_URL="${4:?}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
QUERY_FILE="${SCRIPT_DIR}/query.json"
QUERY=$(cat "$QUERY_FILE")
RESULTS_DIR="${SCRIPT_DIR}/../results"
mkdir -p "$RESULTS_DIR"

echo "=== Scenario B: Warm Steady-State Throughput ==="

# --- Warm-up phase ---
echo "--- Warm-up phase ---"
echo "  Warming up Lambda Zip..."
python3 "${SCRIPT_DIR}/lambda_loadtest.py" "${LAMBDA_ZIP_URL}/search" \
    -n 20 -c 5 --query-file "$QUERY_FILE" > /dev/null 2>&1
echo "  Warming up Lambda Container..."
python3 "${SCRIPT_DIR}/lambda_loadtest.py" "${LAMBDA_CONTAINER_URL}/search" \
    -n 20 -c 5 --query-file "$QUERY_FILE" > /dev/null 2>&1
echo "  Warming up Fargate..."
hey -n 20 -c 5 -m POST -H "Content-Type: application/json" \
    -d "$QUERY" "${FARGATE_URL}/search" > /dev/null 2>&1
echo "  Warming up EC2..."
hey -n 20 -c 5 -m POST -H "Content-Type: application/json" \
    -d "$QUERY" "${EC2_URL}/search" > /dev/null 2>&1
echo "Warm-up complete."
echo ""

# --- Lambda targets (Python SigV4 load tester) ---
for VARIANT in zip container; do
    if [ "$VARIANT" = "zip" ]; then
        URL="${LAMBDA_ZIP_URL}"
    else
        URL="${LAMBDA_CONTAINER_URL}"
    fi
    for CONC in 10 50; do
        echo "=== lambda-${VARIANT} | concurrency=${CONC} | 500 requests ==="
        python3 "${SCRIPT_DIR}/lambda_loadtest.py" "${URL}/search" \
            -n 500 -c "$CONC" --query-file "$QUERY_FILE" \
            --output "${RESULTS_DIR}/scenario-b-lambda-${VARIANT}-c${CONC}.json" \
            --label "Scenario B: Lambda ${VARIANT} c=${CONC}"
        echo ""
        sleep 5
    done
done

# --- Fargate & EC2 (hey) ---
declare -a NAMES=("fargate" "ec2")
declare -a URLS=("${FARGATE_URL}/search" "${EC2_URL}/search")

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
