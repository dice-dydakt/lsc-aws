#!/bin/bash
# Scenario D: Burst from Zero
# Run AFTER Lambda has been idle for 20+ minutes
#
# Uses oha for all targets. SigV4 signing is applied to Lambda URLs.
# All targets are hit simultaneously (background processes).
#
# Usage: ./scenario-d.sh <lambda-zip-url> <lambda-container-url> <fargate-alb-url> <ec2-url>
# Example: ./scenario-d.sh https://abc.lambda-url.us-east-1.on.aws https://def.lambda-url.us-east-1.on.aws http://alb-dns-name http://1.2.3.4:8080

set -euo pipefail

LAMBDA_ZIP_URL="${1:?Usage: $0 <lambda-zip-url> <lambda-container-url> <fargate-alb-url> <ec2-url>}"
LAMBDA_CONTAINER_URL="${2:?}"
FARGATE_URL="${3:?}"
EC2_URL="${4:?}"
source "$(dirname "$0")/oha-helpers.sh"

echo "=== Scenario D: Burst from Zero ==="
echo "Ensure Lambda has been idle for 20+ minutes."
echo "Launching 200 requests at concurrency=50 to ALL targets simultaneously..."
echo ""

oha_lambda -n 200 -c 50 \
    "${LAMBDA_ZIP_URL}/search" 2>&1 | tee "${RESULTS_DIR}/scenario-d-lambda-zip.txt" &

oha_lambda -n 200 -c 50 \
    "${LAMBDA_CONTAINER_URL}/search" 2>&1 | tee "${RESULTS_DIR}/scenario-d-lambda-container.txt" &

oha_http -n 200 -c 50 \
    "${FARGATE_URL}/search" 2>&1 | tee "${RESULTS_DIR}/scenario-d-fargate.txt" &

oha_http -n 200 -c 50 \
    "${EC2_URL}/search" 2>&1 | tee "${RESULTS_DIR}/scenario-d-ec2.txt" &

wait
echo ""
echo "=== Scenario D complete. Results in ${RESULTS_DIR} ==="
