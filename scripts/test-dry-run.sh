#!/usr/bin/env bash
# Exercises the config generator without root and without starting a VPN.
set -euo pipefail

ROOT=$(readlink -f "$(dirname "$0")/..")
SCRIPT=$ROOT/scripts/oneday-vpn.sh
cd "$ROOT"

bash -n "$SCRIPT"
if command -v shellcheck >/dev/null; then
  shellcheck "$SCRIPT"
fi

# shellcheck source=scripts/oneday-vpn.sh
source "$SCRIPT"

assert_roundtrip() {
  local file=$1
  local before after
  before=$(cat "$file")
  ufw_insert_nat "$file" "-A POSTROUTING -s 10.77.0.0/24 -d 192.168.1.0/24 -o eth0 -j MASQUERADE"
  grep -q 'BEGIN ONEDAY-VPN' "$file"
  grep -q -- '-A POSTROUTING -s 10.77.0.0/24 -d 192.168.1.0/24 -o eth0 -j MASQUERADE' "$file"
  ufw_remove_nat "$file"
  after=$(cat "$file")
  [[ $before == "$after" ]]
}

tmp=$(mktemp)
printf '*filter\n:INPUT ACCEPT [0:0]\nCOMMIT\n' >"$tmp"
assert_roundtrip "$tmp"

cat >"$tmp" <<'EOF'
*nat
:POSTROUTING ACCEPT [0:0]
-A POSTROUTING -s 10.0.0.0/8 -j MASQUERADE
COMMIT
*filter
:INPUT ACCEPT [0:0]
COMMIT
EOF
assert_roundtrip "$tmp"

printf '# *nat\n# COMMIT\n*filter\n:INPUT ACCEPT [0:0]\nCOMMIT\n' >"$tmp"
ufw_insert_nat "$tmp" "-A POSTROUTING -s 10.77.0.0/24 -o eth0 -j MASQUERADE"
[[ $(grep -c '^\*nat$' "$tmp") -eq 1 ]]
rm -f "$tmp"

run_setup() {
  bash "$SCRIPT" setup --dry-run "$@"
}

run_setup \
  --lan-if eth0 \
  --lan-ip 192.168.1.20 \
  --lan-cidr 192.168.1.0/24 \
  --endpoint 203.0.113.10:51820 \
  >"$ROOT/dry-run-out-log.txt"

CONF=$ROOT/dry-run-out/home/oneday-client.conf
SERVER=$ROOT/dry-run-out/etc/wireguard/oneday0.conf
STATE=$ROOT/dry-run-out/var/lib/oneday-vpn/state.env
HOWTO=$ROOT/dry-run-out/home/oneday-client-howto.txt
POSTUP=$ROOT/dry-run-out/var/lib/oneday-vpn/postup.sh
POSTDOWN=$ROOT/dry-run-out/var/lib/oneday-vpn/postdown.sh

grep -q 'Dry run only' "$ROOT/dry-run-out-log.txt"
grep -q 'forward UDP 51820 to 192.168.1.20' "$ROOT/dry-run-out-log.txt"
grep -q 'Endpoint = 203.0.113.10:51820' "$CONF"
grep -q 'AllowedIPs = 192.168.1.0/24, 10.77.0.0/24' "$CONF"
grep -q 'PersistentKeepalive = 25' "$CONF"
grep -q 'Import tunnel' "$HOWTO"
grep -q 'ping 192.168.1.20' "$HOWTO"
grep -q 'ListenPort = 51820' "$SERVER"
grep -q 'AllowedIPs = 10.77.0.2/32' "$SERVER"
grep -q 'SaveConfig = false' "$SERVER"
grep -q 'MASQUERADE' "$POSTUP"
grep -q -- '-d 192.168.1.0/24' "$POSTUP"
bash -n "$POSTUP"
bash -n "$POSTDOWN"
if [[ -e $ROOT/dry-run-out/etc/systemd/system/oneday-vpn-expire.timer ]]; then
  echo "setup still installed an automatic shutdown timer" >&2
  exit 1
fi
if grep -q 'Expires:' "$CONF" "$HOWTO"; then
  echo "client files still announce an expiry" >&2
  exit 1
fi
grep -q 'stays up' "$HOWTO"
grep -q 'Stays up until you run: sudo oneday-vpn down' "$ROOT/dry-run-out-log.txt"

client_priv=$(awk -F' = ' '/^PrivateKey/ {print $2; exit}' "$CONF")
server_priv=$(awk -F' = ' '/^PrivateKey/ {print $2; exit}' "$SERVER")
client_psk=$(awk -F' = ' '/^PresharedKey/ {print $2; exit}' "$CONF")
server_psk=$(awk -F' = ' '/^PresharedKey/ {print $2; exit}' "$SERVER")
server_pub_in_client=$(awk -F' = ' '/^PublicKey/ {print $2; exit}' "$CONF")
[[ -n $client_priv && -n $server_priv && $client_priv != "$server_priv" ]]
[[ $client_psk == "$server_psk" ]]
grep -q "PublicKey = ${server_pub_in_client}" "$CONF"
# The server config keeps the server private key and the client public key.
grep -q "$client_priv" "$CONF"
if grep -q "$client_priv" "$SERVER"; then
  echo "client private key leaked into the server config" >&2
  exit 1
fi
if grep -q "$server_priv" "$CONF"; then
  echo "server private key leaked into the client config" >&2
  exit 1
fi
if grep -q "$client_priv" "$STATE" || grep -q "$client_priv" "$HOWTO"; then
  echo "client private key leaked into state or instructions" >&2
  exit 1
fi
if grep -q '0.0.0.0/0' "$CONF"; then
  echo "split tunnel config routes the whole internet" >&2
  exit 1
fi

if command -v wg >/dev/null; then
  derived=$(printf '%s' "$server_priv" | wg pubkey)
  [[ $derived == "$server_pub_in_client" ]]
  [[ ${#client_priv} -eq 44 ]]
fi
# Filename must be a valid interface name so Linux clients can run wg-quick.
sudo wg-quick strip "$SERVER" >/dev/null
sudo wg-quick strip "$CONF" >/dev/null

# Full tunnel routes the client's internet through the server.
run_setup \
  --full-tunnel \
  --lan-if eth0 \
  --lan-ip 192.168.1.20 \
  --lan-cidr 192.168.1.0/24 \
  --endpoint 203.0.113.10:51820 \
  >"$ROOT/dry-run-full.txt"
grep -q '0.0.0.0/0, ::/0' "$ROOT/dry-run-out/home/oneday-client.conf"
grep -q 'all of the client'"'"'s internet traffic' "$ROOT/dry-run-full.txt"
grep -q 'DNS = 1.1.1.1' "$ROOT/dry-run-out/home/oneday-client.conf"
if grep -q -- '-d 192.168.1.0/24' "$ROOT/dry-run-out/var/lib/oneday-vpn/postup.sh"; then
  echo "full tunnel kept the LAN-only destination match" >&2
  exit 1
fi

# A LAN of 10.77.0.0/24 must not be reused as the VPN subnet.
run_setup \
  --lan-if eth0 \
  --lan-ip 10.77.0.20 \
  --lan-cidr 10.77.0.0/24 \
  --endpoint 203.0.113.10:51820 \
  >/dev/null
grep -q 'Address = 10.88.0.2/32' "$ROOT/dry-run-out/home/oneday-client.conf"
grep -q 'Address = 10.88.0.1/24' "$ROOT/dry-run-out/etc/wireguard/oneday0.conf"

# Custom port.
run_setup \
  --lan-if eth0 \
  --lan-ip 192.168.1.20 \
  --lan-cidr 192.168.1.0/24 \
  --endpoint 198.51.100.20:51821 \
  >/dev/null
grep -q 'ListenPort = 51821' "$ROOT/dry-run-out/etc/wireguard/oneday0.conf"
grep -q 'Endpoint = 198.51.100.20:51821' "$ROOT/dry-run-out/home/oneday-client.conf"

# ufw mode writes a NAT rule and an undo script that removes it.
ONEDAY_FIREWALL=ufw run_setup \
  --lan-if eth0 \
  --lan-ip 192.168.1.20 \
  --lan-cidr 192.168.1.0/24 \
  --endpoint 203.0.113.10:51820 \
  >/dev/null
grep -q 'BEGIN ONEDAY-VPN' "$ROOT/dry-run-out/etc/ufw/before.rules"
grep -q 'ufw allow 51820/udp' "$ROOT/dry-run-out/var/lib/oneday-vpn/firewall-plan.txt"
bash "$ROOT/dry-run-out/var/lib/oneday-vpn/firewall-undo.sh" >/dev/null 2>&1
if grep -q 'BEGIN ONEDAY-VPN' "$ROOT/dry-run-out/etc/ufw/before.rules"; then
  echo "ufw undo left the NAT marker in place" >&2
  exit 1
fi

# firewalld mode records the permanent rules it would add.
ONEDAY_FIREWALL=firewalld run_setup \
  --lan-if eth0 \
  --lan-ip 192.168.1.20 \
  --lan-cidr 192.168.1.0/24 \
  --endpoint 203.0.113.10:51820 \
  >/dev/null
grep -q -- '--add-port=51820/udp' "$ROOT/dry-run-out/var/lib/oneday-vpn/firewall-plan.txt"
grep -q -- '--add-source=10.77.0.0/24' "$ROOT/dry-run-out/var/lib/oneday-vpn/firewall-plan.txt"

# Carrier-grade NAT must stop before any config is written.
rm -rf "$ROOT/dry-run-out"
code=0
bash "$SCRIPT" setup --dry-run --public-ip 100.64.1.1 --lan-if eth0 --lan-ip 192.168.1.20 --lan-cidr 192.168.1.0/24 >/tmp/oneday-cgnat.txt 2>&1 || code=$?
[[ $code -eq 2 ]]
grep -q 'Tailscale' /tmp/oneday-cgnat.txt
[[ ! -f $ROOT/dry-run-out/etc/wireguard/oneday0.conf ]]

code=0
bash "$SCRIPT" setup --dry-run --port 80 >/dev/null 2>&1 || code=$?
[[ $code -ne 0 ]]

bash "$SCRIPT" --help >/dev/null

bash "$SCRIPT" tailscale --dry-run --lan-if eth0 --lan-ip 192.168.1.20 --lan-cidr 192.168.1.0/24 \
  >"$ROOT/dry-run-tailscale.txt"
grep -q 'Dry run only' "$ROOT/dry-run-tailscale.txt"
grep -q '192.168.1.0/24' "$ROOT/dry-run-tailscale.txt"
grep -q 'stays up' "$ROOT/dry-run-tailscale.txt"

rm -rf "$ROOT/dry-run-out" "$ROOT/dry-run-out-log.txt" "$ROOT/dry-run-full.txt" "$ROOT/dry-run-tailscale.txt"
echo "ok"
