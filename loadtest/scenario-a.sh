#!/bin/bash
# Scenario A: Lambda Cold Start Characterization
# Run AFTER Lambda has been idle for 20+ minutes
#
# Usage: ./scenario-a.sh <lambda-zip-url> <lambda-container-url>
# Example: ./scenario-a.sh https://abc123.lambda-url.us-east-1.on.aws https://def456.lambda-url.us-east-1.on.aws

set -euo pipefail

LAMBDA_ZIP_URL="${1:?Usage: $0 <lambda-zip-url> <lambda-container-url>}"
LAMBDA_CONTAINER_URL="${2:?Usage: $0 <lambda-zip-url> <lambda-container-url>}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
QUERY=$(cat "${SCRIPT_DIR}/query.json")
RESULTS_DIR="${SCRIPT_DIR}/../results"
mkdir -p "$RESULTS_DIR"

echo "=== Scenario A: Lambda Cold Start Characterization ==="
echo "Ensure Lambda has been idle for 20+ minutes before running."
echo ""

for VARIANT in zip container; do
    if [ "$VARIANT" = "zip" ]; then
        URL="${LAMBDA_ZIP_URL}"
    else
        URL="${LAMBDA_CONTAINER_URL}"
    fi

    OUTFILE="${RESULTS_DIR}/scenario-a-${VARIANT}.txt"
    echo "--- Lambda ${VARIANT} ---" | tee "$OUTFILE"
    echo "URL: ${URL}" | tee -a "$OUTFILE"
    echo "" | tee -a "$OUTFILE"

    for i in $(seq 1 30); do
        echo "Request ${i}/30:" | tee -a "$OUTFILE"

        # Capture timing and response
        RESP=$(curl -s -w '\n{"curl_time_total": %{time_total}, "curl_time_connect": %{time_connect}, "curl_time_starttransfer": %{time_starttransfer}}' \
            -X POST \
            -H "Content-Type: application/json" \
            -D /tmp/headers.txt \
            -d "$QUERY" \
            "${URL}/search" 2>/dev/null)

        # Extract response body (everything before the last line)
        BODY=$(echo "$RESP" | head -n -1)
        TIMING=$(echo "$RESP" | tail -n 1)

        # Extract headers
        COLD_START=$(grep -i "x-cold-start" /tmp/headers.txt 2>/dev/null | tr -d '\r' | awk '{print $2}' || echo "unknown")
        SERVER_TIME=$(grep -i "x-server-time-ms" /tmp/headers.txt 2>/dev/null | tr -d '\r' | awk '{print $2}' || echo "unknown")

        echo "  Cold-Start: ${COLD_START}" | tee -a "$OUTFILE"
        echo "  Server-Time-Ms: ${SERVER_TIME}" | tee -a "$OUTFILE"
        echo "  Timing: ${TIMING}" | tee -a "$OUTFILE"
        echo "  Response: $(echo "$BODY" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(json.dumps({k:d[k] for k in ["query_time_ms","instance_id"]}, indent=None))' 2>/dev/null || echo "$BODY")" | tee -a "$OUTFILE"
        echo "" | tee -a "$OUTFILE"

        sleep 1
    done

    echo "" | tee -a "$OUTFILE"
    echo "Waiting 20 minutes before next variant (for cold start reset)..."
    echo "Press Ctrl+C to skip the wait if running variants separately."

    if [ "$VARIANT" = "zip" ]; then
        echo "Sleeping 1200s (20 min)... Press Ctrl+C and re-run with container URL to skip."
        sleep 1200 || true
    fi
done

echo "=== Scenario A complete. Results in ${RESULTS_DIR} ==="
