# sandbox-lab

A tiny Go HTTP service running inside a **Docker Sandboxes (`sbx`) microVM**,
plus scripts that prove it works and that it is isolated from the host.

- `app/` – stdlib-only Go service, listens on `:8080`
  - `GET /health` → `{"status":"ok"}`
  - `POST /echo` → returns the request body (max 1 MiB)
- `start.sh` – create sandbox `sandbox-lab`, add one allow rule, copy + build + run the app, publish `127.0.0.1:18080 -> 8080`
- `test.sh` – functional checks from the host
- `isolation-test.sh` – isolation checks (all probes run inside the VM via `sbx exec`)
- `teardown.sh` – remove the sandbox, its allow rule, pending approvals, and the marker file

## Prerequisites
- Linux host with KVM; your user in the `kvm` group.
- `docker-sbx` installed (tested with v0.47.0) and `sbx login` completed.
- Global policy initialised once: `sbx policy init deny-all`.
- Recommended: `export SBX_NO_TELEMETRY=1` (the scripts set it too) and
  `ssh.agentForwardingEnabled=false` in sbx settings.
- Host tools: `curl`, `docker` CLI (used read-only for `docker info`, `docker ps`, `docker network inspect`).
- No Go on the host: the app is built **inside** the sandbox with the image's
  Go toolchain, offline (`GOPROXY=off GOTOOLCHAIN=local`).

## Usage
```sh
./start.sh             # create (or reuse) sandbox, build, run, publish 127.0.0.1:18080
./test.sh              # /health, /echo, 405/404, not exposed on the LAN IP
./isolation-test.sh    # PASS/FAIL per check, non-zero exit on any FAIL
./teardown.sh          # remove sandbox, allow rule and marker
```

### Isolation test configuration (env vars)
| Variable | Default | Meaning |
|---|---|---|
| `ALLOW_DOMAIN` | `docs.docker.com:443` | the one allowed egress destination |
| `TARGET_NETWORKS` | *(empty)* | host Docker networks whose container IPs must be unreachable |
| `TARGET_IPS` | *(empty)* | extra IPs that must be unreachable |
| `TARGET_PORTS` | `8080 80 5432` | ports probed on each target IP |
| `HOST_PORTS` | `80 18080` | host ports probed via `host.docker.internal` and the LAN IP |
| `LAN_IP` | first `hostname -I` address | host LAN address to probe |

Example:
```sh
TARGET_NETWORKS="myapp_default" TARGET_IPS="10.0.0.5" HOST_PORTS="80 3000 18080" ./isolation-test.sh
```

Handy extras:
```sh
curl -s http://127.0.0.1:18080/health
curl -s -X POST --data 'hi' http://127.0.0.1:18080/echo
sbx exec -it sandbox-lab bash
sbx policy log sandbox-lab
```

## Hardening
| Item | Setting |
|---|---|
| Global network policy | `deny-all` (locked down) |
| Per-sandbox allow | exactly one (`ALLOW_DOMAIN`), removed by `teardown.sh` |
| Workspace | none – no host bind mount; source copied in with `sbx cp` |
| Port | published on loopback only: `127.0.0.1:18080` |

## What isolation-test.sh checks
1. A random-token marker file in `$HOME` is not visible inside; no host filesystem shares except sbx's read-only `/etc/resolv.conf`.
2. The `docker` inside is a different engine (engine ID differs) and lists none of the host's containers.
3. Container IPs from `TARGET_NETWORKS`/`TARGET_IPS` are blocked on `TARGET_PORTS`, via the proxy and with `--noproxy '*'`.
4. `HOST_PORTS` on `host.docker.internal` and the LAN IP are blocked.
5. `ALLOW_DOMAIN` works; `https://example.com` is denied.
6. UDP/TCP DNS to `1.1.1.1:53` and ICMP to `1.1.1.1` fail.

It cleans up its marker and dismisses the approval prompts its probes created.

## Known limits
- Under deny-all, blocked requests queue approval prompts (`sbx policy approval ls`).
  Approving one opens that destination, including `host.docker.internal`. Don't approve blindly.
- `sbx cp` preserves the host UID; `start.sh` chowns the copied dir to the in-VM `agent` user.
- The VM's DNS resolver answers for allowed names only, but DNS remains a policy-filtered channel.
- `agent` has sudo/docker inside the VM — root in the VM, not on the host.
- If the host reboots, run `sbx daemon start` before `./start.sh`.

## License
MIT – see [LICENSE](LICENSE).
