#!/usr/bin/env bash
# =============================================================================
# verify.sh — Post-deploy smoke test for Chatwoot
# Run after: docker compose up -d
# Usage: bash verify.sh
# =============================================================================
set -euo pipefail

GREEN="\033[0;32m"
RED="\033[0;31m"
YELLOW="\033[1;33m"
NC="\033[0m"

pass() { echo -e "${GREEN}✓ $1${NC}"; }
fail() { echo -e "${RED}✗ $1${NC}"; FAILED=1; }
info() { echo -e "${YELLOW}→ $1${NC}"; }

FAILED=0

echo ""
echo "======================================"
echo "  Chatwoot Post-Deploy Verification"
echo "======================================"
echo ""

# 1. Container status
info "Checking container status..."
for service in rails sidekiq postgres redis; do
  STATUS=$(docker compose ps --format json "$service" 2>/dev/null \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('State','unknown'))" 2>/dev/null \
    || echo "unknown")
  HEALTH=$(docker compose ps --format json "$service" 2>/dev/null \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('Health',''))" 2>/dev/null \
    || echo "")

  if [[ "$STATUS" == "running" ]]; then
    [[ "$HEALTH" == "healthy" ]] && pass "$service: running (healthy)" \
    || [[ -z "$HEALTH" ]] && pass "$service: running" \
    || fail "$service: running but health=$HEALTH"
  else
    fail "$service: status=$STATUS"
  fi
done

# 2. Postgres connectivity
echo ""
info "Checking Postgres connectivity from rails container..."
if docker compose exec -T rails sh -c 'pg_isready -h $POSTGRES_HOST -U $POSTGRES_USERNAME' &>/dev/null; then
  pass "postgres: reachable from rails container"
else
  fail "postgres: NOT reachable from rails container"
fi

# 3. Redis connectivity
echo ""
info "Checking Redis connectivity from rails container..."
if docker compose exec -T rails sh -c 'redis-cli -u $REDIS_URL ping' 2>/dev/null | grep -q PONG; then
  pass "redis: reachable from rails container"
else
  fail "redis: NOT reachable from rails container"
fi

# 4. HTTP response
echo ""
info "Checking HTTP on :3000..."
if curl -sf --max-time 10 http://localhost:3000/auth/sign_in -o /dev/null; then
  pass "rails: HTTP responding on port 3000"
else
  fail "rails: no HTTP response on port 3000 (may still be starting)"
fi

# 5. Summary
echo ""
echo "======================================"
if [[ $FAILED -eq 0 ]]; then
  echo -e "${GREEN}All checks passed!${NC}"
  echo ""
  echo "  Web UI    → http://localhost:3000"
  echo "  Setup     → http://localhost:3000/app/installation/setup"
  echo "  Mailhog   → http://localhost:8025"
else
  echo -e "${RED}Some checks failed. Debug with:${NC}"
  echo "  docker compose logs rails"
  echo "  docker compose logs postgres"
  echo "  docker compose ps"
  exit 1
fi
echo "======================================"
