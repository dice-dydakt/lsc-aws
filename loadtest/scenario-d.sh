#!/bin/bash
# Scenario D: Burst from Zero
# Run AFTER Lambda has been idle for 20+ minutes
#
# Usage: ./scenario-d.sh <lambda-zip-url> <lambda-container-url> <fargate-alb-url> <ec2-url>
# Example: ./scenario-d.sh https://abc.lambda-url.us-east-1.on.aws https://def.lambda-url.us-east-1.on.aws http://alb-dns-name http://1.2.3.4:8080

set -euo pipefail

LAMBDA_ZIP_URL="${1:?Usage: $0 <lambda-zip-url> <lambda-container-url> <fargate-alb-url> <ec2-url>}"
LAMBDA_CONTAINER_URL="${2:?}"
FARGATE_URL="${3:?}"
EC2_URL="${4:?}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
QUERY=$(cat "${SCRIPT_DIR}/query.json")
RESULTS_DIR="${SCRIPT_DIR}/../results"
mkdir -p "$RESULTS_DIR"

echo "=== Scenario D: Burst from Zero ==="
echo "Ensure Lambda has been idle for 20+ minutes."
echo "Launching 200 requests at concurrency=50 to ALL targets simultaneously..."
echo ""

hey -n 200 -c 50 -m POST \
    -H "Content-Type: application/json" \
    -d "$QUERY" \
    "${LAMBDA_ZIP_URL}/search" 2>&1 | tee "${RESULTS_DIR}/scenario-d-lambda-zip.txt" &

hey -n 200 -c 50 -m POST \
    -H "Content-Type: application/json" \
    -d "$QUERY" \
    "${LAMBDA_CONTAINER_URL}/search" 2>&1 | tee "${RESULTS_DIR}/scenario-d-lambda-container.txt" &

hey -n 200 -c 50 -m POST \
    -H "Content-Type: application/json" \
    -d "$QUERY" \
    "${FARGATE_URL}/search" 2>&1 | tee "${RESULTS_DIR}/scenario-d-fargate.txt" &

hey -n 200 -c 50 -m POST \
    -H "Content-Type: application/json" \
    -d "$QUERY" \
    "${EC2_URL}/search" 2>&1 | tee "${RESULTS_DIR}/scenario-d-ec2.txt" &

wait
echo ""
echo "=== Scenario D complete. Results in ${RESULTS_DIR} ==="
