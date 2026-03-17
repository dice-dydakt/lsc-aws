#!/bin/bash
# Shared helpers for scenario scripts using oha with AWS SigV4 auth.
#
# Usage: source this file, then call oha_lambda or oha_http.
#
# oha_lambda: runs oha with SigV4 signing for Lambda Function URLs
# oha_http:   runs oha without signing for Fargate/EC2

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QUERY_FILE="${SCRIPT_DIR}/query.json"
RESULTS_DIR="${SCRIPT_DIR}/../results"
mkdir -p "$RESULTS_DIR"

# Detect oha binary (check PATH, then ~/oha, then fail with install instructions)
if command -v oha &>/dev/null; then
    OHA=oha
elif [ -x "$HOME/oha" ]; then
    OHA="$HOME/oha"
else
    echo "ERROR: oha not found. Install it:"
    echo "  curl -sL https://github.com/hatoo/oha/releases/latest/download/oha-linux-amd64 -o ~/oha && chmod +x ~/oha"
    exit 1
fi

# Load AWS credentials for SigV4 signing
export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-$(aws configure get aws_access_key_id 2>/dev/null)}"
export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-$(aws configure get aws_secret_access_key 2>/dev/null)}"
export AWS_SESSION_TOKEN="${AWS_SESSION_TOKEN:-$(aws configure get aws_session_token 2>/dev/null)}"
AWS_REGION="${AWS_REGION:-us-east-1}"

# oha with SigV4 signing for Lambda
# Note: credentials are passed via CLI args and will be visible in `ps` output.
# This is acceptable for short-lived Academy session tokens on a single-user instance.
# Usage: oha_lambda <oha-args...> <url>
oha_lambda() {
    "$OHA" -m POST -H "Content-Type: application/json" \
        -D "$QUERY_FILE" \
        --aws-sigv4 "aws:amz:${AWS_REGION}:lambda" \
        -a "${AWS_ACCESS_KEY_ID}:${AWS_SECRET_ACCESS_KEY}" \
        --aws-session "${AWS_SESSION_TOKEN}" \
        "$@"
}

# oha without signing for Fargate/EC2
# Usage: oha_http <oha-args...> <url>
oha_http() {
    "$OHA" -m POST -H "Content-Type: application/json" \
        -D "$QUERY_FILE" \
        "$@"
}
