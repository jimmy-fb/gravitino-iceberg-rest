#!/usr/bin/env bash
# verify.sh — smoke-test a running Gravitino Iceberg REST server
#
# Usage:
#   ./scripts/verify.sh <GRAVITINO_HOST> [PORT]
#
# Examples:
#   ./scripts/verify.sh localhost 9001
#   ./scripts/verify.sh 1.2.3.4 30901   # NodePort on EC2/cloud node
#
set -euo pipefail

HOST="${1:?Usage: $0 <host> [port]}"
PORT="${2:-9001}"
BASE="http://${HOST}:${PORT}/iceberg/v1"

echo "==> Checking Gravitino Iceberg REST at ${BASE}"
echo ""

echo "--- [1] Server config ---"
curl -sf "${BASE}/config" | python3 -m json.tool
echo ""

echo "--- [2] List namespaces ---"
curl -sf "${BASE}/namespaces" | python3 -m json.tool
echo ""

echo "--- [3] List tables in 'demo_db' (if it exists) ---"
curl -sf "${BASE}/namespaces/demo_db/tables" | python3 -m json.tool || echo "(namespace 'demo_db' not found — that is OK if no tables have been created yet)"
echo ""

echo "==> All checks passed."
