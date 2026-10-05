#!/bin/bash
# Install Squid forward proxy on an SRA host (lab).
# Defaults: listen 3128, Basic auth shai / 1234!
# Run as root: sudo bash install_squid_proxy.sh
set -euo pipefail

PROXY_PORT="${PROXY_PORT:-3128}"
PROXY_USER="${PROXY_USER:-shai}"
PROXY_PASS="${PROXY_PASS:-1234!}"
CONTAINER_NAME="${CONTAINER_NAME:-squid-proxy}"
IMAGE="${IMAGE:-ubuntu/squid:latest}"

if [[ -n "${PROXY_HOME:-}" ]]; then
  :
elif [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
  PROXY_HOME=$(getent passwd "${SUDO_USER}" | cut -d: -f6)
else
  PROXY_HOME="/root"
fi

PROXY_HOME_OWNER="$(basename "${PROXY_HOME}")"
if ! id "${PROXY_HOME_OWNER}" >/dev/null 2>&1; then
  PROXY_HOME_OWNER="root"
fi

echo "=== install Squid proxy on :${PROXY_PORT} (auth ${PROXY_USER}) home=${PROXY_HOME} ==="

echo "=== narrow 443->8090 redirect (local destinations only) ==="
HANDLE=$(nft -a list chain inet claroty-firewall dynamic-prerouting 2>/dev/null | awk '/redirect to :8090/{for(i=1;i<=NF;i++) if($i=="handle") print $(i+1)}' | tail -1 || true)
if [[ -n "${HANDLE:-}" ]]; then
  nft delete rule inet claroty-firewall dynamic-prerouting handle "${HANDLE}" || true
fi
nft add rule inet claroty-firewall dynamic-prerouting fib daddr type local tcp dport 443 counter redirect to :8090 || true

mkdir -p /etc/nftables/chains.d/dynamic
cat > /etc/nftables/chains.d/dynamic/00-port-forwarding-tcp-443-to-8090.nft <<'EOF'
#!/usr/sbin/nft -f
chain dynamic-prerouting {
    fib daddr type local tcp dport 443 counter redirect to :8090
}
chain dynamic-input {
    meta l4proto tcp tcp dport 8090 ct original proto-dst 443 counter accept
}
EOF

cat > /etc/nftables/sets.d/tcp_accepted_ports.nft <<EOF
#!/usr/sbin/nft -f
set tcp_accepted_ports {
    type inet_service
    flags interval
    auto-merge
    elements = { 21, 53, 3128, 8100, 8118, 9301, ${PROXY_PORT} }
}
EOF
if [[ -f /etc/nftables/sets.d/udp_accepted_ports.nft ]]; then
  cat > /etc/nftables/sets.d/udp_accepted_ports.nft <<'EOF'
#!/usr/sbin/nft -f
set udp_accepted_ports {
    type inet_service
    flags interval
    auto-merge
    elements = { 53 }
}
EOF
fi
systemctl reload nftables || true
nft add element inet claroty-firewall tcp_accepted_ports { 53, 3128, 8100, 8118, "${PROXY_PORT}" } 2>/dev/null || true
nft add element inet claroty-firewall udp_accepted_ports { 53 } 2>/dev/null || true

mkdir -p /opt/squid/config /opt/squid/log

HASH=$(openssl passwd -apr1 "${PROXY_PASS}")
printf '%s:%s\n' "${PROXY_USER}" "${HASH}" > /opt/squid/config/passwd
chmod 644 /opt/squid/config/passwd

cat > /opt/squid/config/squid.conf <<EOF
http_port ${PROXY_PORT}

auth_param basic program /usr/lib/squid/basic_ncsa_auth /etc/squid/passwd
auth_param basic realm Squid Proxy
auth_param basic credentialsttl 2 hours
acl authenticated proxy_auth REQUIRED

acl SSL_ports port 22 2222 443 9301
acl Safe_ports port 22 2222 443 ${PROXY_PORT} 9301
acl CONNECT method CONNECT

http_access deny !Safe_ports
http_access deny CONNECT !SSL_ports
http_access allow authenticated
http_access deny all

cache deny all
maximum_object_size 0 KB
access_log stdio:/var/log/squid/access.log squid
cache_log /var/log/squid/cache.log
cache_store_log none
EOF
chmod 600 /opt/squid/config/squid.conf

cat > "${PROXY_HOME}/proxy.sh" <<EOF
#!/bin/bash
set -euo pipefail
CONTAINER_NAME="${CONTAINER_NAME}"
IMAGE="${IMAGE}"
PROXY_PORT="${PROXY_PORT}"
CONFIG_BIND="/opt/squid/config/squid.conf:/etc/squid/squid.conf:ro"
PASSWD_BIND="/opt/squid/config/passwd:/etc/squid/passwd:ro"

usage() { echo "Usage: proxy.sh [--run|--stop|--status]"; }
ensure_root() { [[ "\${EUID}" -eq 0 ]] || { echo "run as root"; exit 1; }; }
container_exists() { docker ps -a --format "{{.Names}}" | grep -qx "\${CONTAINER_NAME}"; }
container_running() { docker ps --format "{{.Names}}" | grep -qx "\${CONTAINER_NAME}"; }
cmd_status() {
  if ! container_exists; then echo "status: not created"; return 0; fi
  if container_running; then echo "status: running"; else echo "status: stopped"; fi
  docker ps -a --filter "name=^\${CONTAINER_NAME}\$" --format "table {{.ID}}\\t{{.Names}}\\t{{.Image}}\\t{{.Status}}\\t{{.Ports}}"
}
cmd_run() {
  if container_running; then echo "already running"; cmd_status; return 0; fi
  if container_exists; then
    docker start "\${CONTAINER_NAME}"
  else
    docker run -d --name "\${CONTAINER_NAME}" --restart unless-stopped \\
      -p "\${PROXY_PORT}:\${PROXY_PORT}" \\
      -v "\${CONFIG_BIND}" \\
      -v "\${PASSWD_BIND}" \\
      "\${IMAGE}"
  fi
  cmd_status
}
cmd_stop() {
  container_exists || { echo "not created"; return 0; }
  container_running || { echo "already stopped"; return 0; }
  docker stop "\${CONTAINER_NAME}"; cmd_status
}
case "\${1:---help}" in
  --run|-run) ensure_root; cmd_run ;;
  --stop) ensure_root; cmd_stop ;;
  --status) cmd_status ;;
  *) usage ;;
esac
EOF
chmod 750 "${PROXY_HOME}/proxy.sh"
chown "${PROXY_HOME_OWNER}:${PROXY_HOME_OWNER}" "${PROXY_HOME}/proxy.sh" 2>/dev/null || true

docker rm -f squid-proxy http-proxy 2>/dev/null || true
fuser -k "${PROXY_PORT}/tcp" 2>/dev/null || true
docker pull "${IMAGE}"
bash "${PROXY_HOME}/proxy.sh" --run
sleep 4
ss -lntp | grep "${PROXY_PORT}" || true
docker ps --filter "name=${CONTAINER_NAME}"
docker logs "${CONTAINER_NAME}" 2>&1 | tail -20

PROXY_PORT="${PROXY_PORT}" PROXY_USER="${PROXY_USER}" PROXY_PASS="${PROXY_PASS}" python3 - <<'PY'
import base64, os, socket, time

port = int(os.environ["PROXY_PORT"])
user = os.environ["PROXY_USER"]
password = os.environ["PROXY_PASS"]
auth = base64.b64encode(f"{user}:{password}".encode()).decode()
s = None
for i in range(15):
    try:
        s = socket.create_connection(("127.0.0.1", port), timeout=3)
        break
    except Exception as e:
        print("wait", i, e)
        time.sleep(1)
if not s:
    raise SystemExit(f"not listening on {port}")
s.settimeout(10)
req = (
    "CONNECT example.com:443 HTTP/1.1\r\n"
    "Host: example.com:443\r\n"
    f"Proxy-Authorization: Basic {auth}\r\n\r\n"
)
s.sendall(req.encode())
print("CONNECT", s.recv(4096).decode(errors="replace").splitlines()[0])
s.close()
s = socket.create_connection(("127.0.0.1", port), timeout=5)
bad = base64.b64encode(f"{user}:wrong".encode()).decode()
s.sendall(
    (
        "CONNECT example.com:443 HTTP/1.1\r\n"
        "Host: example.com:443\r\n"
        f"Proxy-Authorization: Basic {bad}\r\n\r\n"
    ).encode()
)
print("BAD_AUTH", s.recv(4096).decode(errors="replace").splitlines()[0])
s.close()
PY

echo "DONE proxy=${PROXY_PORT} auth=${PROXY_USER} helper=${PROXY_HOME}/proxy.sh"
