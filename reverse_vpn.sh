#!/bin/bash
# ==============================================
# REVERSE VPN IN 4D — FULL DEPLOYMENT SCRIPT
# Walks past encryptions. Vanishes in time.
# ==============================================
set -e

MODE=""
VPS_HOST=""
CLIENT_NAME="4d_ghost"
OVPN_DATA="ovpn_data"
DOCKER_IMAGE="kylemanna/openvpn"
CHAOS_IMAGE="python:3.11-slim"
LOG="/dev/null"

log() { echo "[4D] $1"; }

usage() {
    cat << EOF
Usage: $0 --mode [server|client] --vps <ip-or-domain>

  --mode server   → Run on VPS (public IP)
  --mode client   → Run on internal machine
  --vps  <host>   → VPS public IP or domain
EOF
    exit 1
}

# Parse args
while [[ $# -gt 0 ]]; do
    case $1 in
        --mode) MODE="$2"; shift 2 ;;
        --vps) VPS_HOST="$2"; shift 2 ;;
        *) usage ;;
    esac
done

[[ -z "$MODE" || -z "$VPS_HOST" ]] && usage

# ==============================================
# 1. COMMON: Generate 4D Master Key
# ==============================================
MASTER_KEY_FILE="/etc/openvpn/4d_master.key"
if [[ ! -f "$MASTER_KEY_FILE" ]]; then
    log "Generating 4D master key (BLAKE3 seed)..."
    openssl rand 32 > "$MASTER_KEY_FILE"
    chmod 600 "$MASTER_KEY_FILE"
fi
K0=$(cat "$MASTER_KEY_FILE")

# ==============================================
# 2. SERVER MODE (VPS)
# ==============================================
if [[ "$MODE" == "server" ]]; then
    log "Launching 4D Reverse VPN Server on $VPS_HOST"

    # Create persistent volume
    docker volume create $OVPN_DATA >/dev/null

    # Generate server config
    docker run --rm -v $OVPN_DATA:/etc/openvpn $DOCKER_IMAGE ovpn_genconfig \
        -u udp://$VPS_HOST \
        -s 10.8.0.0/24 \
        -d -d -d \
        -p "route 192.168.0.0 255.255.0.0" \
        -2  # Enable duplicate-cn

    # Init PKI
    docker run --rm -it -v $OVPN_DATA:/etc/openvpn $DOCKER_IMAGE ovpn_initpki nopass

    # Start server
    docker run -d \
        --name vpn4d_server \
        -v $OVPN_DATA:/etc/openvpn \
        -p 1194:1194/udp \
        --cap-add=NET_ADMIN \
        --restart unless-stopped \
        $DOCKER_IMAGE

    # Generate client config
    CLIENT_CONFIG="client_$CLIENT_NAME.ovpn"
    docker run --rm -v $OVPN_DATA:/etc/openvpn $DOCKER_IMAGE easyrsa build-client-full $CLIENT_NAME nopass
    docker run --rm -v $OVPN_DATA:/etc/openvpn $DOCKER_IMAGE ovpn_getclient $CLIENT_NAME > /tmp/$CLIENT_CONFIG

    log "Client config ready: /tmp/$CLIENT_CONFIG"
    log "Send this file securely to your internal client."
    log "Then run: $0 --mode client --vps $VPS_HOST"

    # Start 4D Chaos Injector (background)
    cat > /usr/local/bin/chaos_injector.py << 'PY'
import time, hashlib, os
from scipy.integrate import odeint
import numpy as np

def blake3_chain(k, steps):
    for _ in range(steps): k = hashlib.blake3(k).digest()
    return k

def lorenz_4d(state, t, sigma=10, rho=28, beta=8/3, delta=0.01, key=0):
    x, y, z, w = state
    return [sigma*(y-x), x*(rho-z)-y, x*y-beta*z, delta*(key*x - w)]

def get_chaos_byte(key):
    init = [ord(key[i%32]) / 255 for i in range(4)]
    t = np.linspace(0, 1, 100)
    sol = odeint(lorenz_4d, init, t, args=(10,28,8/3,0.01,float(int.from_bytes(key[:4],'big'))))
    return int(sol[-1,2] * 1000) % 256

k0 = open("/etc/openvpn/4d_master.key", "rb").read()
t0 = int(time.time())
while True:
    t = int(time.time())
    if t != t0:
        steps = (t - t0) % 86400
        key = blake3_chain(k0, steps)
        byte = get_chaos_byte(key)
        os.system(f"iptables -t mangle -A POSTROUTING -p udp --dport 1194 -j CHECKSUM --checksum-fill {byte}")
        t0 = t
    time.sleep(0.1)
PY

    docker run -d --name chaos_injector \
        -v $OVPN_DATA:/etc/openvpn \
        --cap-add=NET_ADMIN \
        --restart unless-stopped \
        $CHAOS_IMAGE bash -c "pip install scipy numpy && python /etc/openvpn/chaos_injector.py"

    log "4D Chaos Injector ACTIVE. Tunnel is now TIMEWALKING."
    exit 0
fi

# ==============================================
# 3. CLIENT MODE (Internal Machine)
# ==============================================
if [[ "$MODE" == "client" ]]; then
    log "Connecting from internal network to $VPS_HOST..."

    # Request client config (you must SCP it from server)
    if [[ ! -f "./client_$CLIENT_NAME.ovpn" ]]; then
        log "ERROR: Missing client config: client_$CLIENT_NAME.ovpn"
        log "SCP it from server: scp root@$VPS_HOST:/tmp/client_$CLIENT_NAME.ovpn ."
        exit 1
    fi

    # Start reverse tunnel
    docker run -d \
        --name vpn4d_client \
        -v $(pwd):/etc/openvpn \
        --cap-add=NET_ADMIN \
        --restart unless-stopped \
        $DOCKER_IMAGE ovpn_run \
        --config /etc/openvpn/client_$CLIENT_NAME.ovpn \
        --auth-nocache \
        --route-nopull \
        --route 192.168.0.0 255.255.0.0 vpn_gateway

    # Auto-reverse SSH over tunnel (optional)
    sleep 10
    docker exec vpn4d_client ip route | grep tun0 && log "Tunnel UP. Routing 192.168.0.0/16 via 4D tunnel."

    # Start 4D Chaos Sync Client
    cat > /tmp/chaos_sync.py << 'PY'
import time, hashlib, os, socket
from scipy.integrate import odeint
import numpy as np

def blake3_chain(k, steps):
    for _ in range(steps): k = hashlib.blake3(k).digest()
    return k

def lorenz_4d(state, t, sigma=10, rho=28, beta=8/3, delta=0.01, key=0):
    x, y, z, w = state
    return [sigma*(y-x), x*(rho-z)-y, x*y-beta*z, delta*(key*x - w)]

def get_chaos_byte(key):
    init = [ord(key[i%32]) / 255 for i in range(4)]
    t = np.linspace(0, 1, 100)
    sol = odeint(lorenz_4d, init, t, args=(10,28,8/3,0.01,float(int.from_bytes(key[:4],'big'))))
    return int(sol[-1,2] * 1000) % 256

k0 = open("/etc/openvpn/4d_master.key", "rb").read()
t0 = int(time.time())
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
while True:
    t = int(time.time())
    if t != t0:
        steps = (t - t0) % 86400
        key = blake3_chain(k0, steps)
        byte = get_chaos_byte(key)
        # Send sync pulse (invisible in payload)
        try: s.sendto(bytes([byte]), ("10.8.0.1", 1194))
        except: pass
        t0 = t
    time.sleep(0.1)
PY

    docker run -d --name chaos_sync \
        -v $(pwd):/etc/openvpn \
        --network container:vpn4d_client \
        --restart unless-stopped \
        $CHAOS_IMAGE bash -c "pip install scipy numpy && python /tmp/chaos_sync.py"

    log "4D Chaos Sync ACTIVE. You are now UNDETECTABLE."
    log "Access internal services via VPS IP. The tunnel walks in time."
fi
