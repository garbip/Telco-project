
#!/usr/bin/env bash
set -euo pipefail

# Run as root
if [[ "$EUID" -ne 0 ]]; then
    echo "Please run with: sudo bash setup.sh"
    exit 1
fi

# Network configuration
DOCKER_BRIDGE="br-85f8e7ec124f"
NGINX_IP="10.0.3.10"

echo "=== Creating network namespaces ==="

for ns in ue access core; do
    if ! ip netns list | awk '{print $1}' | grep -Fxq "$ns"; then
        ip netns add "$ns"
        echo "Created namespace: $ns"
    fi
done

echo "=== Creating UE-Access link ==="

if ! ip -n ue link show ue-access >/dev/null 2>&1; then
    ip link add ue-access type veth peer name access-ue
    ip link set ue-access netns ue
    ip link set access-ue netns access
fi

echo "=== Creating Access-Core link ==="

if ! ip -n access link show access-core >/dev/null 2>&1; then
    ip link add access-core type veth peer name core-access
    ip link set access-core netns access
    ip link set core-access netns core
fi

echo "=== Creating Core-Host link ==="

if ! ip -n core link show core-host >/dev/null 2>&1; then
    if ip link show host-core >/dev/null 2>&1; then
        echo "ERROR: host-core already exists but core-host is missing."
        echo "Check the veth pair manually before rerunning."
        exit 1
    fi

    ip link add core-host type veth peer name host-core
    ip link set core-host netns core
fi

if ! ip link show host-core >/dev/null 2>&1; then
    echo "ERROR: host-core interface is missing."
    exit 1
fi

echo "=== Configuring IP addresses ==="

ip -n ue addr replace 10.0.1.2/24 dev ue-access

ip -n access addr replace 10.0.1.1/24 dev access-ue
ip -n access addr replace 10.0.2.1/24 dev access-core

ip -n core addr replace 10.0.2.2/24 dev core-access
ip -n core addr replace 10.0.4.2/24 dev core-host

ip addr replace 10.0.4.1/24 dev host-core

echo "=== Enabling interfaces ==="

ip -n ue link set lo up
ip -n ue link set ue-access up

ip -n access link set lo up
ip -n access link set access-ue up
ip -n access link set access-core up

ip -n core link set lo up
ip -n core link set core-access up
ip -n core link set core-host up

ip link set host-core up

echo "=== Configuring routes ==="

ip -n ue route replace default via 10.0.1.1
ip -n access route replace 10.0.3.0/24 via 10.0.2.2
ip -n core route replace 10.0.1.0/24 via 10.0.2.1
ip -n core route replace 10.0.3.0/24 via 10.0.4.1
ip route replace 10.0.1.0/24 via 10.0.4.2 dev host-core

echo "=== Enabling IP forwarding ==="

sysctl -w net.ipv4.ip_forward=1
ip netns exec access sysctl -w net.ipv4.ip_forward=1

sysctl -w net.ipv4.conf.host-core.forwarding=1
sysctl -w "net.ipv4.conf.${DOCKER_BRIDGE}.forwarding=1"

echo "=== Checking Docker bridge ==="

if ! ip link show "$DOCKER_BRIDGE" >/dev/null 2>&1; then
    echo "ERROR: Docker bridge $DOCKER_BRIDGE not found."
    echo "Start Docker and ensure the telco-data network exists."
    exit 1
fi

if ! ip -4 addr show dev "$DOCKER_BRIDGE" | grep -q '10\.0\.3\.1/24'; then
    echo "ERROR: Expected 10.0.3.1/24 on $DOCKER_BRIDGE."
    exit 1
fi

echo "=== Configuring targeted NAT ==="

iptables -t nat -C POSTROUTING \
    -s 10.0.4.0/24 -d 10.0.3.0/24 \
    -o "$DOCKER_BRIDGE" -j MASQUERADE 2>/dev/null ||
iptables -t nat -I POSTROUTING 1 \
    -s 10.0.4.0/24 -d 10.0.3.0/24 \
    -o "$DOCKER_BRIDGE" -j MASQUERADE
iptables -t nat -C POSTROUTING \
    -s 10.0.1.0/24 -d 10.0.3.0/24 \
    -o "$DOCKER_BRIDGE" -j MASQUERADE 2>/dev/null ||
iptables -t nat -I POSTROUTING 1 \
    -s 10.0.1.0/24 -d 10.0.3.0/24 \
    -o "$DOCKER_BRIDGE" -j MASQUERADE

echo "=== Configuring Docker forwarding ==="

iptables -C DOCKER-USER \
    -i host-core -o "$DOCKER_BRIDGE" \
    -d "$NGINX_IP" -j ACCEPT 2>/dev/null ||
iptables -I DOCKER-USER 1 \
    -i host-core -o "$DOCKER_BRIDGE" \
    -d "$NGINX_IP" -j ACCEPT

iptables -C DOCKER-USER \
    -i "$DOCKER_BRIDGE" -o host-core \
    -s "$NGINX_IP" \
    -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null ||
iptables -I DOCKER-USER 1 \
    -i "$DOCKER_BRIDGE" -o host-core \
    -s "$NGINX_IP" \
    -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

echo "=== Checking for the known nftables blocker ==="

# Remove only the exact blocking rule if it exists.
# Use a rule handle because nft cannot delete a rule by expression.
if nft list chain ip raw PREROUTING >/dev/null 2>&1; then
    while true; do
        HANDLE=$(
            nft -a list chain ip raw PREROUTING |
            awk -v ip="$NGINX_IP" '
                index($0, "ip daddr " ip) &&
                index($0, "iifname != \"'"$DOCKER_BRIDGE"'\"") &&
                $0 ~ / drop( # handle [0-9]+)?$/ {
                    if (match($0, /# handle [0-9]+$/)) {
                        h = substr($0, RSTART + 9, RLENGTH - 9)
                        print h
                        exit
                    }
                }
            '
        )

        [[ -n "$HANDLE" ]] || break

        nft delete rule ip raw PREROUTING handle "$HANDLE"
        echo "Removed blocking nftables rule (handle $HANDLE)."
    done
fi

echo "=== Checking Nginx container ==="

if docker ps --format '{{.Names}}' | grep -Fxq telco-nginx; then
    echo "Nginx container is running."
else
    echo "WARNING: telco-nginx is not running."
    echo "Start it with: sudo docker start telco-nginx"
fi

echo
echo "=== SETUP DONE ==="
echo "UE:       10.0.1.2"
echo "Access:   10.0.1.1 / 10.0.2.1"
echo "Core:     10.0.2.2 / 10.0.4.2"
echo "Host:     10.0.4.1"
echo "Nginx:    ${NGINX_IP}"
