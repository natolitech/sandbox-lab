#!/bin/sh
# Remove the sandbox-lab sandbox, its sandbox-scoped policy rules, and the marker.
set -u
export SBX_NO_TELEMETRY=1
NAME=sandbox-lab
ALLOW_DOMAIN=${ALLOW_DOMAIN:-docs.docker.com:443}
sbx policy rm network --sandbox "$NAME" --resource "$ALLOW_DOMAIN" -f 2>/dev/null && echo "[teardown] removed allow rule $ALLOW_DOMAIN" || echo "[teardown] no allow rule to remove"
for id in $(sbx policy approval ls 2>/dev/null | awk -v n="$NAME" 'NR>1 && $2==n {print $1}'); do
  sbx policy approval respond "$id" --option dismiss >/dev/null 2>&1 || true
done
if sbx ls 2>/dev/null | awk 'NR>1{print $1}' | grep -qx "$NAME"; then
  sbx rm -f "$NAME" && echo "[teardown] sandbox $NAME removed"
else
  echo "[teardown] sandbox $NAME not present"
fi
rm -f "$HOME/.sandbox-lab-marker" && echo "[teardown] marker removed"
sbx ls
sbx policy ls --wide
