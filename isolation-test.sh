#!/bin/sh
# Isolation checks for the sandbox-lab sandbox. Runs on the host; every probe
# executes inside the microVM via `sbx exec`. Prints PASS/FAIL per check and
# exits non-zero if any check fails.
set -u
export SBX_NO_TELEMETRY=1
NAME=sandbox-lab
ALLOW_DOMAIN=${ALLOW_DOMAIN:-docs.docker.com:443}
ALLOW_HOST=${ALLOW_DOMAIN%%:*}
DENY_HOST=example.com
fail=0
pass()  { echo "PASS  $1"; }
failm() { echo "FAIL  $1"; fail=1; }
inbox() { sbx exec "$NAME" sh -c "$1"; }
inbox_root() { sbx exec -u root "$NAME" sh -c "$1"; }

sbx ls 2>/dev/null | awk 'NR>1{print $1}' | grep -qx "$NAME" || { echo "sandbox $NAME not found; run ./start.sh" >&2; exit 2; }

# Classify an HTTP probe made inside the sandbox.
#  REACHED  = a real HTTP response came back from the target
#  BLOCKED  = connection failed/empty, or the sbx egress proxy refused it
probe() { # $1=url $2=extra curl flags
  inbox "out=\$(curl -sS -m 5 $2 -o /tmp/probe.body -w '%{http_code}' '$1' 2>/dev/null); rc=\$?;
         if [ \"\$out\" = 000 ]; then echo BLOCKED rc=\$rc;
         elif grep -Eq '^(Approval required for|Blocked by network policy:)' /tmp/probe.body 2>/dev/null; then echo BLOCKED proxy-\$out;
         else echo REACHED http-\$out; fi"
}

echo "== sandbox-lab isolation tests ($(date '+%F %T %Z'))"

# 1. Host files ------------------------------------------------------------
MARK_NAME=".sandbox-lab-marker"
MARK="$HOME/$MARK_NAME"
TOKEN="sbxlab-$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
echo "$TOKEN" > "$MARK"
r=$(inbox "test -e '$MARK' && echo SEEN-PATH; test -d '$HOME' && echo SEEN-HOME; find / -xdev -name '$MARK_NAME' 2>/dev/null | head -1 | sed 's/^/SEEN-FIND:/'; grep -rqs '$TOKEN' /home /tmp /mnt /workspace 2>/dev/null && echo SEEN-TOKEN; true")
[ -z "$r" ] && pass "host marker file ($MARK) not visible inside" || failm "host marker visible inside: $r"
# sbx itself shares the generated /etc/resolv.conf read-only over virtiofs; any
# other host share (virtiofs/9p/fuse) is a failure.
r=$(inbox "mount | grep -E 'virtiofs|9p|fuse' | grep -Ev ' on /etc/resolv.conf type virtiofs \\(ro[,)]' || true")
[ -z "$r" ] && pass "no host filesystem shares mounted (only sbx's read-only /etc/resolv.conf)" || failm "host shares mounted: $r"

# 2. Docker socket / engine -----------------------------------------------
HOST_ENGINE=$(docker info --format '{{.ID}}')
IN_ENGINE=$(inbox "docker info --format '{{.ID}}' 2>/dev/null || echo none")
if [ "$IN_ENGINE" = none ]; then pass "no docker engine reachable inside"
elif [ "$IN_ENGINE" != "$HOST_ENGINE" ]; then pass "inner docker is a separate engine (inner $IN_ENGINE != host $HOST_ENGINE)"
else failm "inner docker IS the host engine ($IN_ENGINE)"; fi
# Inner docker must not list any of the host's containers.
_hc=$(mktemp); _ic=$(mktemp)
docker ps -a --format '{{.Names}}' 2>/dev/null | sort -u > "$_hc"
inbox "docker ps -a --format '{{.Names}}' 2>/dev/null" | sort -u > "$_ic"
r=$(comm -12 "$_hc" "$_ic" | tr '\n' ' '); rm -f "$_hc" "$_ic"
[ -z "$r" ] && pass "host containers not listed by inner docker" || failm "host containers visible: $r"
r=$(inbox "ls /var/run/docker.sock /run/docker.sock 2>/dev/null; mount | grep -c docker.sock || true")
echo "INFO  inner socket(s): $(echo $r)  (belongs to the sandbox's own engine, see engine-ID check)"

# 3. Host container IPs -----------------------------------------------------
# TARGET_NETWORKS: space-separated host docker networks whose container IPs to probe
# TARGET_IPS:      extra space-separated IPs to probe
# TARGET_PORTS:    ports to probe on each IP (default "8080 80 5432")
TARGET_NETWORKS=${TARGET_NETWORKS:-}
TARGET_PORTS=${TARGET_PORTS:-8080 80 5432}
NET_IPS=$(for n in $TARGET_NETWORKS; do
  docker network inspect "$n" --format '{{range .Containers}}{{.IPv4Address}} {{end}}' 2>/dev/null; done | tr ' ' '\n' | sed 's#/.*##' | grep .)
IPS=$(printf '%s\n' $NET_IPS ${TARGET_IPS:-} | grep . | sort -u)
if [ -z "$IPS" ]; then echo "INFO  no TARGET_NETWORKS/TARGET_IPS set; skipping container-IP probes"; fi
for ip in $IPS; do
  for port in $TARGET_PORTS; do
    for mode in proxy direct; do
      [ $mode = direct ] && fl="--noproxy '*'" || fl=""
      res=$(probe "http://$ip:$port/" "$fl")
      case "$res" in BLOCKED*) pass "container $ip:$port ($mode) blocked [$res]";; *) failm "container $ip:$port ($mode) reachable [$res]";; esac
    done
  done
done

# 4. Host services ---------------------------------------------------------
# HOST_PORTS: host ports to probe via host.docker.internal and the LAN IP (default "80 18080")
HOST_PORTS=${HOST_PORTS:-80 18080}
LAN_IP=${LAN_IP:-$(hostname -I | awk '{print $1}')}
for port in $HOST_PORTS; do for tgt in "host.docker.internal:$port" "$LAN_IP:$port"; do
  for mode in proxy direct; do
    [ $mode = direct ] && fl="--noproxy '*'" || fl=""
    res=$(probe "http://$tgt/" "$fl")
    case "$res" in BLOCKED*) pass "host $tgt ($mode) blocked [$res]";; *) failm "host $tgt ($mode) reachable [$res]";; esac
  done
done; done

# 5. Egress policy -----------------------------------------------------------
res=$(probe "https://$ALLOW_HOST/" "")
case "$res" in REACHED*) pass "allowed domain $ALLOW_HOST reachable [$res]";; *) failm "allowed domain $ALLOW_HOST not reachable [$res]";; esac
for mode in proxy direct; do
  [ $mode = direct ] && fl="--noproxy '*'" || fl=""
  res=$(probe "https://$DENY_HOST/" "$fl")
  case "$res" in BLOCKED*) pass "$DENY_HOST ($mode) denied [$res]";; *) failm "$DENY_HOST ($mode) reachable [$res]";; esac
done

# 6. UDP and ICMP ------------------------------------------------------------
r=$(inbox "dig @1.1.1.1 example.com +time=3 +tries=1 +short >/dev/null 2>&1; echo \$?")
[ "$r" != 0 ] && pass "UDP DNS to 1.1.1.1:53 fails (dig rc=$r)" || failm "UDP DNS to 1.1.1.1:53 succeeded"
r=$(inbox "dig @1.1.1.1 example.com +tcp +time=3 +tries=1 +short >/dev/null 2>&1; echo \$?")
[ "$r" != 0 ] && pass "TCP DNS to 1.1.1.1:53 fails (dig rc=$r)" || failm "TCP DNS to 1.1.1.1:53 succeeded"
# No ping binary in the image; send a raw ICMP echo as root with python3.
r=$(inbox_root "python3 - <<'PY'
import socket, struct, time
def csum(b):
    s=sum(struct.unpack('!%dH'%(len(b)//2), b)); s=(s>>16)+(s&0xffff); s+=s>>16; return (~s)&0xffff
try:
    sk=socket.socket(socket.AF_INET, socket.SOCK_RAW, socket.IPPROTO_ICMP); sk.settimeout(3)
except Exception as e:
    print('NOSOCK', e); raise SystemExit
pay=b'sandbox-lab'; hdr=struct.pack('!BBHHH',8,0,0,0x5b1,1); pkt=struct.pack('!BBHHH',8,0,csum(hdr+pay+b'\0'*(len(pay)%2)),0x5b1,1)+pay
try:
    sk.sendto(pkt,('1.1.1.1',0))
except Exception as e:
    print('SENDFAIL', e); raise SystemExit
end=time.time()+3
while time.time()<end:
    try: d,a=sk.recvfrom(1024)
    except socket.timeout: break
    if a[0]=='1.1.1.1' and d[20]==0: print('REPLY'); raise SystemExit
print('NOREPLY')
PY")
case "$r" in REPLY*) failm "ICMP echo to 1.1.1.1 got a reply";; NOREPLY*|SENDFAIL*) pass "ICMP echo to 1.1.1.1 gets no reply [$r]";; *) failm "ICMP test inconclusive [$r]";; esac

# Cleanup: marker file + dismiss approval prompts this run generated, so nobody
# approves a test probe by accident later.
rm -f "$MARK"
for id in $(sbx policy approval ls 2>/dev/null | awk -v n="$NAME" 'NR>1 && $2==n {print $1}'); do
  sbx policy approval respond "$id" --option dismiss >/dev/null 2>&1 || true
done

echo
[ $fail -eq 0 ] && echo "isolation-test.sh: ALL PASS" || echo "isolation-test.sh: FAILURES (see FAIL lines)"
exit $fail
