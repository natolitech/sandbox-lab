#!/bin/sh
# Create the sandbox-lab microVM sandbox, build the Go app inside it, run it,
# and publish 127.0.0.1:18080 -> 8080. Idempotent: reuses an existing sandbox.
set -eu
export SBX_NO_TELEMETRY=1
NAME=sandbox-lab
HOST_PORT=18080
DIR=$(cd "$(dirname "$0")" && pwd)
APP_DST=/home/agent/sandbox-lab-app
ALLOW_DOMAIN=${ALLOW_DOMAIN:-docs.docker.com:443}

if ! sbx policy ls >/dev/null 2>&1; then
  echo "Global policy not initialised; run: sbx policy init deny-all" >&2; exit 1
fi

if sbx ls 2>/dev/null | awk 'NR>1{print $1}' | grep -qx "$NAME"; then
  echo "[start] sandbox $NAME already exists; reusing it"
else
  echo "[start] creating sandbox $NAME (shell agent, no workspace mount)"
  # No PATH argument => no host bind mount at all.
  sbx create --name "$NAME" -q -p "127.0.0.1:${HOST_PORT}:8080" shell
fi

# One explicit, sandbox-scoped allow rule so the egress test has a known-good domain.
if ! sbx policy ls --wide "$NAME" 2>/dev/null | grep -q "$ALLOW_DOMAIN"; then
  echo "[start] adding sandbox-scoped allow rule: $ALLOW_DOMAIN"
  sbx policy allow network --sandbox "$NAME" "$ALLOW_DOMAIN"
fi

# Make sure the port is published (no-op error if already published).
sbx ports "$NAME" --publish "127.0.0.1:${HOST_PORT}:8080" >/dev/null 2>&1 || true

echo "[start] copying source into sandbox"
sbx exec "$NAME" rm -rf "$APP_DST"
sbx cp "$DIR/app" "$NAME:$APP_DST"
# sbx cp keeps the host UID (1003); give the copy to the sandbox user (uid 1000)
sbx exec -u root "$NAME" chown -R agent:agent "$APP_DST"

echo "[start] building with the sandbox's own Go toolchain (offline, stdlib only)"
sbx exec -w "$APP_DST" -e CGO_ENABLED=0 -e GOPROXY=off -e GOTOOLCHAIN=local -e GOFLAGS=-mod=mod \
  "$NAME" go build -trimpath -o "$APP_DST/sandbox-lab" .

echo "[start] (re)starting server on :8080 inside the sandbox"
sbx exec "$NAME" sh -c 'pkill -x sandbox-lab 2>/dev/null || true'
sbx exec "$NAME" sh -c "cd $APP_DST && setsid nohup ./sandbox-lab >server.log 2>&1 </dev/null & sleep 1"

i=0
until curl -fsS "http://127.0.0.1:${HOST_PORT}/health" >/dev/null 2>&1; do
  i=$((i+1)); [ $i -ge 30 ] && { echo "[start] server did not come up; log:" >&2; sbx exec "$NAME" cat "$APP_DST/server.log" >&2; exit 1; }
  sleep 1
done
echo "[start] up: http://127.0.0.1:${HOST_PORT}"
sbx ls
