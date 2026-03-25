#!/usr/bin/env bash
# verify.sh — smoke-test a running Gravitino + OAuth setup
#
# Usage:
#   ./scripts/verify.sh <NODE_HOST> [GRAVITINO_NODE_PORT] [OAUTH_NODE_PORT]
#
# Examples:
#   ./scripts/verify.sh localhost                # port-forwarded defaults
#   ./scripts/verify.sh 1.2.3.4 30901 30902      # NodePort on cloud node
#
set -euo pipefail

HOST="${1:?Usage: $0 <host> [gravitino_port] [oauth_port]}"
GRAVITINO_PORT="${2:-30901}"
OAUTH_PORT="${3:-30902}"

GRAVITINO_BASE="http://${HOST}:${GRAVITINO_PORT}/iceberg/v1"
OAUTH_URL="http://${HOST}:${OAUTH_PORT}/oauth/tokens"

CLIENT_ID="${OAUTH_CLIENT_ID:-firebolt}"
CLIENT_SECRET="${OAUTH_CLIENT_SECRET:-firebolt-secret}"

echo "==> Smoke-testing Gravitino + OAuth"
echo "    Gravitino : ${GRAVITINO_BASE}"
echo "    OAuth     : ${OAUTH_URL}"
echo ""

# ── 1. OAuth server health ────────────────────────────────────────────────────
echo "--- [1] OAuth server health ---"
curl -sf "http://${HOST}:${OAUTH_PORT}/health" | python3 -m json.tool
echo ""

# ── 2. Fetch a token ─────────────────────────────────────────────────────────
echo "--- [2] Fetch OAuth token (client_credentials) ---"
TOKEN_RESPONSE=$(curl -sf -X POST "${OAUTH_URL}" \
  -d "grant_type=client_credentials&client_id=${CLIENT_ID}&client_secret=${CLIENT_SECRET}")
echo "${TOKEN_RESPONSE}" | python3 -m json.tool
ACCESS_TOKEN=$(echo "${TOKEN_RESPONSE}" | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")
echo "Token obtained (first 40 chars): ${ACCESS_TOKEN:0:40}..."
echo ""

# ── 3. Gravitino config (authenticated) ──────────────────────────────────────
echo "--- [3] Gravitino /config (with Bearer token) ---"
curl -sf "${GRAVITINO_BASE}/config" \
  -H "Authorization: Bearer ${ACCESS_TOKEN}" | python3 -m json.tool
echo ""

# ── 4. List namespaces ────────────────────────────────────────────────────────
echo "--- [4] List namespaces ---"
curl -sf "${GRAVITINO_BASE}/namespaces" \
  -H "Authorization: Bearer ${ACCESS_TOKEN}" | python3 -m json.tool
echo ""

# ── 5. List tables in demo_db (if it exists) ──────────────────────────────────
echo "--- [5] List tables in demo_db ---"
curl -sf "${GRAVITINO_BASE}/namespaces/demo_db/tables" \
  -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  | python3 -m json.tool \
  || echo "(namespace 'demo_db' not found — OK if no tables exist yet)"
echo ""

echo "==> All checks passed."
