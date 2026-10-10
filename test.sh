#!/bin/sh
# Functional tests from the host against the published port.
set -u
BASE=${BASE:-http://127.0.0.1:18080}
fail=0
pass() { echo "PASS  $1"; }
failm() { echo "FAIL  $1"; fail=1; }

got=$(curl -fsS -m 5 "$BASE/health" 2>&1) || got="ERR: $got"
[ "$got" = '{"status":"ok"}' ] && pass "GET /health -> $got" || failm "GET /health -> $got"

payload='{"hello":"sandbox","n":42}'
got=$(curl -fsS -m 5 -X POST -H 'Content-Type: application/json' --data "$payload" "$BASE/echo" 2>&1) || got="ERR: $got"
[ "$got" = "$payload" ] && pass "POST /echo returns body" || failm "POST /echo -> $got"

code=$(curl -s -o /dev/null -w '%{http_code}' -m 5 "$BASE/echo")
[ "$code" = 405 ] && pass "GET /echo -> 405" || failm "GET /echo -> $code (want 405)"

code=$(curl -s -o /dev/null -w '%{http_code}' -m 5 "$BASE/nope")
[ "$code" = 404 ] && pass "GET /nope -> 404" || failm "GET /nope -> $code (want 404)"

# Published only on loopback: LAN IP must not answer.
LAN_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
if [ -n "$LAN_IP" ]; then
  if curl -s -m 3 -o /dev/null "http://$LAN_IP:18080/health"; then failm "port 18080 reachable on LAN IP $LAN_IP"; else pass "port 18080 not reachable on LAN IP $LAN_IP"; fi
fi

[ $fail -eq 0 ] && echo "test.sh: ALL PASS" || echo "test.sh: FAILURES"
exit $fail
