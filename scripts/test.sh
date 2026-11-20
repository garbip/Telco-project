#!/usr/bin/env bash
# discover-5g.sh - read-only inventory + tests for the Project 1 Scenario B lab
# (docker_open5gs / UERANSIM). It changes nothing.
#
# Usage:   sudo bash discover-5g.sh
# Output:  printed on screen and saved to ~/telco-map-<timestamp>.txt
# Review the file before sharing it: it has IPs and container names, no keys.

if [[ $EUID -ne 0 ]]; then
    echo "Run with: sudo bash $0"
    exit 1
fi

BASE="${SUDO_USER:+/home/$SUDO_USER}"
OUT="${BASE:-$HOME}/telco-map-$(date +%Y%m%d-%H%M%S).txt"
exec > >(tee "$OUT") 2>&1

sec() { printf '\n==================== %s ====================\n' "$*"; }
run() { printf '$ %s\n' "$*"; bash -c "$*" 2>&1 || printf '(command failed, exit %s)\n' "$?"; }
find_c() { docker ps --format '{{.Names}}' | grep -E "$1" | head -1; }
ip_of() { docker inspect "$1" --format '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' 2>/dev/null; }
dx() {
    local c="$1"; shift
    if [[ -z "$c" ]]; then echo "(container not found)"; return; fi
    printf '$ docker exec %s %s\n' "$c" "$*"
    docker exec "$c" sh -c "$*" 2>&1 || printf '(failed, exit %s)\n' "$?"
}

UE=$(find_c '^nr_ue$|^ue$|scenario-b-ue|ueransim.*ue')
GNB=$(find_c 'gnb')
UPF=$(find_c '^upf$|scenario-b-upf')
AMF=$(find_c '^amf$|scenario-b-amf')
SMF=$(find_c '^smf$|scenario-b-smf')
NGINX=$(find_c 'nginx')
IPERF=$(find_c 'iperf')
PROM=$(find_c 'prometheus')
GRAF=$(find_c 'grafana')

sec "0. Detected roles"
echo "UE=$UE  gNB=$GNB  UPF=$UPF  AMF=$AMF  SMF=$SMF"
echo "NGINX=${NGINX:-none}  IPERF=${IPERF:-none}  PROMETHEUS=${PROM:-none}  GRAFANA=${GRAF:-none}"

sec "1. Host resources (sizing for Jenkins/ZAP/Juice Shop later)"
run "date; uname -r"
run "lscpu | grep -E 'Model name|^CPU\(s\)'"
run "grep -o -m1 -w avx /proc/cpuinfo || echo 'NO AVX flag'"
run "free -h"
run "df -h /"
run "docker --version; docker compose version"
run "sysctl net.ipv4.ip_forward"

sec "2. Containers"
run "docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'"
sec "2b. Container -> network=IP"
docker ps -q | xargs -r docker inspect --format '{{.Name}}: {{range $k,$v := .NetworkSettings.Networks}}{{$k}}={{$v.IPAddress}}  {{end}}'

sec "3. Docker networks (subnet, gateway, host bridge, members)"
for n in $(docker network ls --format '{{.Name}}'); do
    echo "--- $n"
    docker network inspect "$n" --format 'driver={{.Driver}} bridge=br-{{printf "%.12s" .Id}} subnets={{range .IPAM.Config}}{{.Subnet}} gw={{.Gateway}} {{end}}'
    docker network inspect "$n" --format '{{range .Containers}}    {{.Name}} {{.IPv4Address}}{{"\n"}}{{end}}'
done

sec "4. Compose project and 5G parameters"
run "docker compose ls"
for f in $(find "${BASE:-$HOME}" -maxdepth 4 -name .env -path '*open5gs*' 2>/dev/null); do
    echo "## $f"
    grep -E '_IP=|MCC|MNC|UE_IPV4|DNN|APN|TEST_NETWORK|DOCKER_HOST_IP' "$f"
done

sec "5. UE"
dx "$UE" "ip -br addr"
dx "$UE" "ip route"
dx "$UE" "ip rule"
run "docker inspect ${UE:-none} --format '{{range .Mounts}}{{.Source}} -> {{.Destination}}{{\"\\n\"}}{{end}}'"
dx "$UE" 'for f in $(find / -maxdepth 4 -name "*ue*.yaml" -not -path "/proc/*" 2>/dev/null); do echo "## $f"; grep -E "mcc|mnc|apn|sst|gnbSearchList|- 1" "$f" | head -15; done'

sec "6. gNB"
dx "$GNB" "ip -br addr"
dx "$GNB" 'for f in $(find / -maxdepth 4 -name "*gnb*.yaml" -not -path "/proc/*" 2>/dev/null); do echo "## $f"; grep -E "mcc|mnc|linkIp|ngapIp|gtpIp|address|port|sst" "$f" | head -20; done'

sec "7. UPF (N3 / N6 / ogstun)"
dx "$UPF" "ip -br addr"
dx "$UPF" "ip route"
dx "$UPF" "cat /proc/sys/net/ipv4/ip_forward"
dx "$UPF" "iptables -t nat -S 2>/dev/null || echo 'iptables not available in container'"

sec "8. Registration / PDU session evidence in logs"
echo "--- AMF"
[[ -n "$AMF" ]] && docker logs --tail 500 "$AMF" 2>&1 | grep -iE 'registration|InitialUEMessage|security mode|SUPI|NGSetup|gNB' | tail -12
echo "--- SMF"
[[ -n "$SMF" ]] && docker logs --tail 500 "$SMF" 2>&1 | grep -iE 'PDU|PFCP|session|IPv4' | tail -12
echo "--- UPF"
[[ -n "$UPF" ]] && docker logs --tail 500 "$UPF" 2>&1 | grep -iE 'PFCP|session|ogstun' | tail -12

sec "9. UE tests"
dx "$UE" "ping -I uesimtun0 -c 3 -W 2 8.8.8.8"
for target in "$NGINX" "$IPERF"; do
    [[ -z "$target" ]] && continue
    for ip in $(ip_of "$target"); do
        echo "--- $target ($ip)"
        dx "$UE" "ip route get $ip"
        dx "$UE" "ping -I uesimtun0 -c 3 -W 2 $ip"
        dx "$UE" "curl -s -o /dev/null -m 5 --interface uesimtun0 -w 'http=%{http_code} connect=%{time_connect}s total=%{time_total}s\n' http://$ip/"
    done
done
[[ -z "$NGINX$IPERF" ]] && echo "No Nginx or iperf3 container found: a data network with services still needs to be added."

sec "10. Host firewall (rules that can block Docker routing)"
run "iptables -S DOCKER-USER"
run "nft list chain ip raw PREROUTING"

sec "DONE"
echo "Saved to: $OUT"
