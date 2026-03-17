#!/bin/bash
# Scenario A: Lambda Cold Start Characterization
# Run AFTER Lambda has been idle for 20+ minutes
#
# Automatically uses the Python SigV4 load tester for Lambda URLs
# (required when Function URLs use --auth-type AWS_IAM, as on Academy accounts).
#
# Usage: ./scenario-a.sh <lambda-zip-url> <lambda-container-url>
# Example: ./scenario-a.sh https://abc123.lambda-url.us-east-1.on.aws https://def456.lambda-url.us-east-1.on.aws

set -euo pipefail

LAMBDA_ZIP_URL="${1:?Usage: $0 <lambda-zip-url> <lambda-container-url>}"
LAMBDA_CONTAINER_URL="${2:?Usage: $0 <lambda-zip-url> <lambda-container-url>}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RESULTS_DIR="${SCRIPT_DIR}/../results"
QUERY_FILE="${SCRIPT_DIR}/query.json"
mkdir -p "$RESULTS_DIR"

echo "=== Scenario A: Lambda Cold Start Characterization ==="
echo "Ensure Lambda has been idle for 20+ minutes before running."
echo ""

echo "--- Lambda Zip (30 sequential requests, 1s delay) ---"
python3 "${SCRIPT_DIR}/lambda_loadtest.py" "${LAMBDA_ZIP_URL}/search" \
    -n 30 --sequential-delay 1.0 --query-file "$QUERY_FILE" \
    --output "${RESULTS_DIR}/scenario-a-zip.json" --label "Scenario A: Zip"

echo ""
echo "Waiting 20 minutes before container variant (for cold start reset)..."
echo "Press Ctrl+C to skip the wait if running variants separately."
echo "Sleeping 1200s (20 min)..."
sleep 1200 || true

echo ""
echo "--- Lambda Container (30 sequential requests, 1s delay) ---"
python3 "${SCRIPT_DIR}/lambda_loadtest.py" "${LAMBDA_CONTAINER_URL}/search" \
    -n 30 --sequential-delay 1.0 --query-file "$QUERY_FILE" \
    --output "${RESULTS_DIR}/scenario-a-container.json" --label "Scenario A: Container"

echo ""
echo "=== Scenario A complete. Results in ${RESULTS_DIR} ==="
echo ""
echo "Next: check CloudWatch for Init Duration (cold start) entries:"
echo "  aws logs filter-log-events --log-group-name /aws/lambda/lsc-knn-zip --filter-pattern 'Init Duration' --start-time \$(date -d '30 minutes ago' +%s000) --query 'events[*].message' --output text"
echo "  aws logs filter-log-events --log-group-name /aws/lambda/lsc-knn-container --filter-pattern 'Init Duration' --start-time \$(date -d '30 minutes ago' +%s000) --query 'events[*].message' --output text"
