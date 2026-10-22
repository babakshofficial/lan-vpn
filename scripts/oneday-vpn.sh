#!/usr/bin/env bash
# Share the LAN this computer is on with one client.
# The tunnel stays up until you run: sudo oneday-vpn down
#
# Download and run on the Linux computer that is on that LAN:
#   curl -fsSL https://raw.githubusercontent.com/babakshofficial/lan-vpn/main/scripts/oneday-vpn.sh -o oneday-vpn.sh
#   sudo bash oneday-vpn.sh setup
#   sudo bash oneday-vpn.sh tailscale
#   sudo oneday-vpn status
#   sudo oneday-vpn down
set -euo pipefail

IFACE=oneday0
PORT=51820
DRY_RUN=0
FULL_TUNNEL=0
REPLACE=0
EXPIRED=0
QUIET=0
PORT_SET=0
CMD=""
ENDPOINT_OVERRIDE=""
LAN_IF_OVERRIDE=""
LAN_IP_OVERRIDE=""
LAN_CIDR_OVERRIDE=""
PUBLIC_IP_OVERRIDE=""
PLACEHOLDER_ENDPOINT=0
PLACEHOLDER_LAN=0
SETUP_READY=0
FIREWALL=iptables
STATE_DIR=/var/lib/oneday-vpn
UNIT_DIR=/etc/systemd/system
WG_CONF=/etc/wireguard/${IFACE}.conf
SYSCTL_FILE=/etc/sysctl.d/99-oneday-vpn.conf
UFW_BEFORE_RULES=/etc/ufw/before.rules
SCRIPT_PATH=$(readlink -f "${BASH_SOURCE[0]}")

usage() {
  cat <<EOF
Download on the Linux computer that is on your LAN, then run:

  curl -fsSL https://raw.githubusercontent.com/babakshofficial/lan-vpn/main/scripts/oneday-vpn.sh -o oneday-vpn.sh
  sudo bash oneday-vpn.sh setup [--full-tunnel] [--endpoint HOST:PORT]
  sudo bash oneday-vpn.sh tailscale
  sudo oneday-vpn status
  sudo oneday-vpn show
  sudo oneday-vpn down

setup       Start WireGuard and write a one-client config. It stays up until you stop it.
tailscale   Use when setup reports CGNAT, or when you cannot forward a UDP port
status      Show whether the tunnel is up
show        Print the client config again
down        Turn the VPN off and revoke the client
            down --expired   only cancels an older 24-hour timer and leaves the VPN up

Options:
  --port N           UDP listen port (default 51820)
  --endpoint HOST[:PORT]
  --public-ip ADDR   Skip the public-IP lookup
  --full-tunnel      Send all of the client's internet traffic through this computer
  --lan-if NAME      Interface facing your LAN
  --lan-ip ADDR      This computer's address on that LAN
  --lan-cidr CIDR    Subnet the client may reach
  --replace          Replace an existing one-day VPN
  --dry-run          Write the configs under ./dry-run-out and do not change the system
EOF
}

die() {
  echo "error: $*" >&2
  exit 1
}

log_msg() {
  [[ "${DRY_RUN:-0}" == 1 ]] && return 0
  printf '%s %s\n' "$(date -Is)" "$*" >>/var/log/oneday-vpn.log 2>/dev/null || true
}

is_private_or_cgnat() {
  local ip=$1
  [[ $ip =~ ^10\. ]] && return 0
  [[ $ip =~ ^192\.168\. ]] && return 0
  [[ $ip =~ ^127\. ]] && return 0
  [[ $ip =~ ^169\.254\. ]] && return 0
  [[ $ip =~ ^172\.(1[6-9]|2[0-9]|3[0-1])\. ]] && return 0
  [[ $ip =~ ^100\.(6[4-9]|[7-9][0-9]|1[0-1][0-9]|12[0-7])\. ]] && return 0
  return 1
}

normalize_cidr() {
  python3 -c 'import ipaddress,sys; print(ipaddress.ip_network(sys.argv[1], strict=False))' "$1"
}

ip_in_net() {
  python3 -c 'import ipaddress,sys; ip=ipaddress.ip_address(sys.argv[1]); net=ipaddress.ip_network(sys.argv[2], strict=False); sys.exit(0 if ip in net else 1)' "$1" "$2"
}

cidr_overlaps() {
  python3 -c 'import ipaddress,sys; a=ipaddress.ip_network(sys.argv[1], strict=False); b=ipaddress.ip_network(sys.argv[2], strict=False); sys.exit(0 if a.overlaps(b) else 1)' "$1" "$2"
}

valid_ipv4() {
  python3 -c 'import ipaddress,sys; ipaddress.ip_address(sys.argv[1])' "$1" >/dev/null 2>&1
}

validate_token() {
  local name=$1 value=$2
  [[ $value =~ ^[A-Za-z0-9_.:/-]+$ ]] || die "${name} has unexpected characters"
}

require_root() {
  [[ $DRY_RUN == 1 ]] && return 0
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die "Run this as root: sudo bash ${SCRIPT_PATH} ${CMD:-setup}"
}

have_systemd() {
  command -v systemctl >/dev/null && [[ -d /run/systemd/system ]]
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help|help)
        usage
        exit 0
        ;;
      --port)
        [[ $# -ge 2 ]] || die "--port needs a number"
        PORT=$2
        PORT_SET=1
        shift 2
        ;;
      --endpoint)
        [[ $# -ge 2 ]] || die "--endpoint needs a host"
        ENDPOINT_OVERRIDE=$2
        shift 2
        ;;
      --public-ip)
        [[ $# -ge 2 ]] || die "--public-ip needs an address"
        PUBLIC_IP_OVERRIDE=$2
        shift 2
        ;;
      --lan-if)
        [[ $# -ge 2 ]] || die "--lan-if needs a name"
        LAN_IF_OVERRIDE=$2
        shift 2
        ;;
      --lan-ip)
        [[ $# -ge 2 ]] || die "--lan-ip needs an address"
        LAN_IP_OVERRIDE=$2
        shift 2
        ;;
      --lan-cidr)
        [[ $# -ge 2 ]] || die "--lan-cidr needs a subnet"
        LAN_CIDR_OVERRIDE=$2
        shift 2
        ;;
      --full-tunnel)
        FULL_TUNNEL=1
        shift
        ;;
      --replace)
        REPLACE=1
        shift
        ;;
      --dry-run)
        DRY_RUN=1
        shift
        ;;
      --expired)
        EXPIRED=1
        shift
        ;;
      --quiet)
        QUIET=1
        shift
        ;;
      setup|up|down|revoke|status|show|tailscale)
        [[ -z $CMD ]] || die "Only one command is allowed"
        CMD=$1
        shift
        ;;
      *)
        die "Unknown argument: $1"
        ;;
    esac
  done

  [[ $PORT =~ ^[0-9]+$ ]] || die "--port must be a whole number"
  [[ $PORT -ge 1024 && $PORT -le 65535 ]] || die "--port must be from 1024 to 65535"
}

prepare_dirs() {
  if [[ $DRY_RUN == 1 ]]; then
    DRY_ROOT=${ONEDAY_DRY_ROOT:-$PWD/dry-run-out}
    [[ -n $DRY_ROOT && $DRY_ROOT != / && $DRY_ROOT != "$PWD" ]] || die "Refusing this dry-run directory"
    rm -rf "$DRY_ROOT"
    STATE_DIR=$DRY_ROOT/var/lib/oneday-vpn
    UNIT_DIR=$DRY_ROOT/etc/systemd/system
    WG_CONF=$DRY_ROOT/etc/wireguard/${IFACE}.conf
    SYSCTL_FILE=$DRY_ROOT/etc/sysctl.d/99-oneday-vpn.conf
    mkdir -p "$STATE_DIR" "$(dirname "$WG_CONF")" "$(dirname "$SYSCTL_FILE")" "$UNIT_DIR" "$DRY_ROOT/home"
  fi
  mkdir -p "$STATE_DIR"
  chmod 700 "$STATE_DIR" 2>/dev/null || true
}

install_packages() {
  [[ $DRY_RUN == 1 ]] && return 0
  if command -v wg >/dev/null && command -v wg-quick >/dev/null && command -v iptables >/dev/null \
    && command -v python3 >/dev/null && command -v curl >/dev/null && command -v ip >/dev/null; then
    command -v qrencode >/dev/null || true
    return 0
  fi
  export DEBIAN_FRONTEND=noninteractive
  if command -v apt-get >/dev/null; then
    apt-get update -y
    apt-get install -y wireguard wireguard-tools iptables curl python3 iproute2 ca-certificates
    apt-get install -y qrencode || true
  elif command -v dnf >/dev/null; then
    dnf install -y wireguard-tools iptables curl python3 iproute qrencode || dnf install -y wireguard-tools iptables curl python3 iproute
  elif command -v pacman >/dev/null; then
    pacman -Sy --noconfirm wireguard-tools iptables curl python iproute2 qrencode || pacman -Sy --noconfirm wireguard-tools iptables curl python iproute2
  elif command -v zypper >/dev/null; then
    zypper --non-interactive install wireguard-tools iptables curl python3 iproute2
    zypper --non-interactive install qrencode || true
  else
    die "Install wireguard-tools, iptables, curl, python3, and iproute2, then run this again"
  fi
  command -v wg >/dev/null || die "wireguard-tools is still missing after install"
  command -v python3 >/dev/null || die "python3 is still missing after install"
}

ensure_basics() {
  [[ $DRY_RUN == 1 ]] && return 0
  if ! command -v ip >/dev/null || ! command -v curl >/dev/null || ! command -v python3 >/dev/null; then
    install_packages
  fi
  command -v python3 >/dev/null || die "python3 is required"
  command -v ip >/dev/null || die "iproute2 is required (the ip command)"
  command -v curl >/dev/null || die "curl is required, or pass --endpoint"
}

detect_lan() {
  if [[ $DRY_RUN == 1 && -z $LAN_IF_OVERRIDE && -z $LAN_IP_OVERRIDE && -z $LAN_CIDR_OVERRIDE ]] \
    && ! command -v ip >/dev/null; then
    LAN_IF=eth0
    LAN_IP=192.168.1.20
    LAN_CIDR=192.168.1.0/24
    GATEWAY=192.168.1.1
    PLACEHOLDER_LAN=1
    return 0
  fi

  if [[ -n $LAN_IF_OVERRIDE ]]; then
    LAN_IF=$LAN_IF_OVERRIDE
  else
    LAN_IF=$(ip -4 route show default | awk '{for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i + 1); exit }}')
  fi
  [[ -n ${LAN_IF:-} ]] || die "Could not find the default network interface. Pass --lan-if"
  validate_token "interface" "$LAN_IF"

  local addr_cidr=""
  if command -v ip >/dev/null; then
    addr_cidr=$(ip -4 -o addr show dev "$LAN_IF" | awk '{print $4; exit}')
  fi

  if [[ -n $LAN_IP_OVERRIDE ]]; then
    LAN_IP=$LAN_IP_OVERRIDE
  else
    [[ -n $addr_cidr ]] || die "Could not find an IPv4 address on ${LAN_IF}. Pass --lan-ip"
    LAN_IP=${addr_cidr%%/*}
  fi
  valid_ipv4 "$LAN_IP" || die "LAN IP ${LAN_IP} is not a valid IPv4 address"

  if [[ -n $LAN_CIDR_OVERRIDE ]]; then
    LAN_CIDR=$(normalize_cidr "$LAN_CIDR_OVERRIDE")
  elif [[ -n $addr_cidr ]]; then
    LAN_CIDR=$(normalize_cidr "$addr_cidr")
  elif [[ $DRY_RUN == 1 && -n $LAN_IP_OVERRIDE && -n $LAN_IF_OVERRIDE ]]; then
    die "Pass --lan-cidr with --lan-ip in a dry run"
  else
    die "Could not determine the LAN subnet. Pass --lan-cidr, for example 192.168.1.0/24"
  fi
  ip_in_net "$LAN_IP" "$LAN_CIDR" || die "LAN IP ${LAN_IP} is outside ${LAN_CIDR}"

  GATEWAY=""
  if command -v ip >/dev/null; then
    GATEWAY=$(ip -4 route show default | awk '{for (i = 1; i <= NF; i++) if ($i == "via") { print $(i + 1); exit }}')
  fi
}

fetch_public_ip() {
  local url ip
  for url in https://ipv4.icanhazip.com https://api.ipify.org https://ifconfig.me/ip; do
    ip=$(curl -4 -fsS --max-time 8 "$url" 2>/dev/null | tr -d '[:space:]') || true
    if [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && valid_ipv4 "$ip"; then
      printf '%s' "$ip"
      return 0
    fi
  done
  return 1
}

resolve_endpoint() {
  ENDPOINT_PORT=$PORT
  if [[ -n $ENDPOINT_OVERRIDE ]]; then
    if [[ $ENDPOINT_OVERRIDE =~ ^([0-9.]+):([0-9]+)$ ]]; then
      ENDPOINT_HOST=${BASH_REMATCH[1]}
      ENDPOINT_PORT=${BASH_REMATCH[2]}
      PORT=$ENDPOINT_PORT
      PORT_SET=1
      valid_ipv4 "$ENDPOINT_HOST" || die "--endpoint IP is not valid"
    elif [[ $ENDPOINT_OVERRIDE =~ ^[A-Za-z0-9.-]+$ ]]; then
      ENDPOINT_HOST=$ENDPOINT_OVERRIDE
    else
      die "--endpoint must look like 203.0.113.10, 203.0.113.10:51820, or vpn.example.com"
    fi
    [[ $ENDPOINT_PORT =~ ^[0-9]+$ && $ENDPOINT_PORT -ge 1024 && $ENDPOINT_PORT -le 65535 ]] \
      || die "Endpoint port must be from 1024 to 65535"
    PUBLIC_IP=${PUBLIC_IP_OVERRIDE:-$ENDPOINT_HOST}
    return 0
  fi

  if [[ -n $PUBLIC_IP_OVERRIDE ]]; then
    PUBLIC_IP=$PUBLIC_IP_OVERRIDE
    valid_ipv4 "$PUBLIC_IP" || die "--public-ip is not a valid IPv4 address"
  elif [[ $DRY_RUN == 1 ]]; then
    PUBLIC_IP=203.0.113.10
    PLACEHOLDER_ENDPOINT=1
  else
    PUBLIC_IP=$(fetch_public_ip) || die "Could not discover this computer's public IP. Re-run with --endpoint YOUR_PUBLIC_IP:${PORT}"
  fi
  ENDPOINT_HOST=$PUBLIC_IP
  ENDPOINT_PORT=$PORT
}

refuse_if_unreachable() {
  if [[ -n $ENDPOINT_OVERRIDE ]]; then
    return 0
  fi
  if ! is_private_or_cgnat "$PUBLIC_IP"; then
    return 0
  fi
  cat <<EOF
This computer's public address is ${PUBLIC_IP}.
That address is a private or carrier-grade NAT address, so a client on the
internet cannot open a UDP port to this computer. Port forwarding will not work.

The VPN was not started. Run Tailscale instead. It reaches this computer
without a port forward, and it stays up until you turn it off:

  sudo bash ${SCRIPT_PATH} tailscale

Then approve the subnet in https://login.tailscale.com/admin/machines
and have the client sign in to the same Tailscale account.
EOF
  exit 2
}

port_busy() {
  local p=$1
  command -v ss >/dev/null || return 1
  ss -uln | awk '{print $5}' | grep -Eq "(^|:)${p}$"
}

choose_port() {
  local start=$PORT candidate i
  if [[ $PORT_SET == 1 ]]; then
    if [[ $DRY_RUN == 0 ]] && port_busy "$PORT"; then
      die "UDP port ${PORT} is already in use. Pass another --port"
    fi
    ENDPOINT_PORT=$PORT
    return 0
  fi
  for i in 0 1 2 3 4 5 6 7 8 9 10; do
    candidate=$((start + i))
    [[ $candidate -le 65535 ]] || break
    if [[ $DRY_RUN == 1 ]] || ! port_busy "$candidate"; then
      PORT=$candidate
      ENDPOINT_PORT=$PORT
      return 0
    fi
  done
  die "UDP ports ${start} through $((start + 10)) are in use. Pass --port"
}

choose_vpn_net() {
  local candidate
  for candidate in 10.77.0.0/24 10.88.0.0/24 10.99.0.0/24 10.66.0.0/24 172.31.250.0/24; do
    if ! cidr_overlaps "$candidate" "$LAN_CIDR"; then
      VPN_NET=$candidate
      read -r VPN_SERVER_IP VPN_CLIENT_IP < <(python3 -c 'import ipaddress,sys; hosts=list(ipaddress.ip_network(sys.argv[1]).hosts()); print(hosts[0], hosts[1])' "$candidate")
      VPN_PREFIX=${VPN_NET##*/}
      return 0
    fi
  done
  die "Every built-in VPN subnet overlaps ${LAN_CIDR}"
}

gen_material() {
  if command -v wg >/dev/null; then
    SERVER_PRIV=$(wg genkey | tr -d '[:space:]')
    CLIENT_PRIV=$(wg genkey | tr -d '[:space:]')
    PSK=$(wg genpsk | tr -d '[:space:]')
    SERVER_PUB=$(printf '%s' "$SERVER_PRIV" | wg pubkey | tr -d '[:space:]')
    CLIENT_PUB=$(printf '%s' "$CLIENT_PRIV" | wg pubkey | tr -d '[:space:]')
  elif [[ $DRY_RUN == 1 ]]; then
    SERVER_PRIV=$(head -c 32 /dev/urandom | base64 | tr -d '[:space:]')
    CLIENT_PRIV=$(head -c 32 /dev/urandom | base64 | tr -d '[:space:]')
    PSK=$(head -c 32 /dev/urandom | base64 | tr -d '[:space:]')
    SERVER_PUB=$(printf '%s' "$SERVER_PRIV" | sha256sum | awk '{print substr($1,1,43)}')"="
    CLIENT_PUB=$(printf '%s' "$CLIENT_PRIV" | sha256sum | awk '{print substr($1,1,43)}')"="
  else
    die "wg is not installed"
  fi
}

write_state() {
  {
    printf 'MODE=%q\n' "$MODE"
    printf 'LAN_IF=%q\n' "$LAN_IF"
    printf 'LAN_IP=%q\n' "$LAN_IP"
    printf 'LAN_CIDR=%q\n' "$LAN_CIDR"
    printf 'GATEWAY=%q\n' "${GATEWAY:-}"
    printf 'VPN_NET=%q\n' "${VPN_NET:-}"
    printf 'PORT=%q\n' "$PORT"
    printf 'ENDPOINT_HOST=%q\n' "${ENDPOINT_HOST:-}"
    printf 'ENDPOINT_PORT=%q\n' "${ENDPOINT_PORT:-$PORT}"
    printf 'FULL_TUNNEL=%q\n' "$FULL_TUNNEL"
    printf 'CLIENT_CONF_PATH=%q\n' "${CLIENT_CONF_PATH:-}"
    printf 'CLIENT_HOWTO_PATH=%q\n' "${CLIENT_HOWTO_PATH:-}"
    printf 'CLIENT_PNG_PATH=%q\n' "${CLIENT_PNG_PATH:-}"
    printf 'IP_FORWARD_PREV=%q\n' "${IP_FORWARD_PREV:-1}"
    printf 'RP_ALL_PREV=%q\n' "${RP_ALL_PREV:-}"
    printf 'RP_LAN_PREV=%q\n' "${RP_LAN_PREV:-}"
    printf 'FIREWALL=%q\n' "$FIREWALL"
    printf 'TAILSCALE_PREEXISTING=%q\n' "${TAILSCALE_PREEXISTING:-0}"
    printf 'OLD_ROUTES=%q\n' "${OLD_ROUTES:-}"
    printf 'NEED_FORWARD=%q\n' "${NEED_FORWARD:-0}"
  } >"$STATE_DIR/state.env"
  chmod 600 "$STATE_DIR/state.env"
}

emit_pair() {
  local ipt=$1 spec=$2 postup=$3 postdown=$4
  local check=${spec/-A /-C }
  local del=${spec/-A /-D }
  printf 'if ! %s %s 2>/dev/null; then %s %s; fi\n' "$ipt" "$check" "$ipt" "$spec" >>"$postup"
  printf '%s %s || true\n' "$ipt" "$del" >>"$postdown"
}

write_hook_scripts() {
  local ipt postup postdown dest_flag src_flag
  ipt=$(command -v iptables || true)
  if [[ -z $ipt ]]; then
    [[ $DRY_RUN == 1 ]] || die "iptables is not installed"
    ipt=/usr/sbin/iptables
  fi
  validate_token "iptables" "$ipt"
  postup=$STATE_DIR/postup.sh
  postdown=$STATE_DIR/postdown.sh
  : >"$postup"
  : >"$postdown"
  chmod 700 "$postup" "$postdown"
  {
    echo "#!/bin/bash"
    echo "set -euo pipefail"
  } | tee "$postup" "$postdown" >/dev/null
  # tee overwrote the files, so the shebang is present once. Re-chmod.
  chmod 700 "$postup" "$postdown"

  if [[ $FULL_TUNNEL == 1 ]]; then
    emit_pair "$ipt" "-A FORWARD -i ${IFACE} -o ${LAN_IF} -j ACCEPT" "$postup" "$postdown"
    emit_pair "$ipt" "-A FORWARD -i ${LAN_IF} -o ${IFACE} -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT" "$postup" "$postdown"
    emit_pair "$ipt" "-t nat -A POSTROUTING -s ${VPN_NET} -o ${LAN_IF} -j MASQUERADE" "$postup" "$postdown"
    dest_flag=""
    src_flag=""
    NAT_RULE="-A POSTROUTING -s ${VPN_NET} -o ${LAN_IF} -j MASQUERADE"
  else
    emit_pair "$ipt" "-A FORWARD -i ${IFACE} -o ${LAN_IF} -d ${LAN_CIDR} -m conntrack --ctstate NEW,ESTABLISHED,RELATED -j ACCEPT" "$postup" "$postdown"
    emit_pair "$ipt" "-A FORWARD -i ${LAN_IF} -o ${IFACE} -s ${LAN_CIDR} -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT" "$postup" "$postdown"
    emit_pair "$ipt" "-t nat -A POSTROUTING -s ${VPN_NET} -d ${LAN_CIDR} -o ${LAN_IF} -j MASQUERADE" "$postup" "$postdown"
    dest_flag="-d ${LAN_CIDR}"
    src_flag="-s ${LAN_CIDR}"
    NAT_RULE="-A POSTROUTING -s ${VPN_NET} -d ${LAN_CIDR} -o ${LAN_IF} -j MASQUERADE"
  fi
  emit_pair "$ipt" "-A INPUT -i ${IFACE} -s ${VPN_NET} -j ACCEPT" "$postup" "$postdown"
  printf '%s -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -i %s -j TCPMSS --clamp-mss-to-pmtu || true\n' "$ipt" "$IFACE" >>"$postup"
  printf '%s -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -o %s -j TCPMSS --clamp-mss-to-pmtu || true\n' "$ipt" "$IFACE" >>"$postup"
  printf '%s -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -i %s -j TCPMSS --clamp-mss-to-pmtu || true\n' "$ipt" "$IFACE" >>"$postdown"
  printf '%s -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -o %s -j TCPMSS --clamp-mss-to-pmtu || true\n' "$ipt" "$IFACE" >>"$postdown"
  printf 'sysctl -w net.ipv4.conf.%s.rp_filter=2 >/dev/null || true\n' "$IFACE" >>"$postup"

  cat >>"$postup" <<EOF
if ${ipt} -nL DOCKER-USER >/dev/null 2>&1; then
  if ! ${ipt} -C DOCKER-USER -i ${IFACE} -o ${LAN_IF} ${dest_flag} -j ACCEPT 2>/dev/null; then
    ${ipt} -I DOCKER-USER 1 -i ${IFACE} -o ${LAN_IF} ${dest_flag} -j ACCEPT || true
  fi
  if ! ${ipt} -C DOCKER-USER -i ${LAN_IF} -o ${IFACE} ${src_flag} -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null; then
    ${ipt} -I DOCKER-USER 1 -i ${LAN_IF} -o ${IFACE} ${src_flag} -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT || true
  fi
fi
EOF
  cat >>"$postdown" <<EOF
if ${ipt} -nL DOCKER-USER >/dev/null 2>&1; then
  ${ipt} -D DOCKER-USER -i ${IFACE} -o ${LAN_IF} ${dest_flag} -j ACCEPT || true
  ${ipt} -D DOCKER-USER -i ${LAN_IF} -o ${IFACE} ${src_flag} -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT || true
fi
EOF
}

write_server_conf() {
  mkdir -p "$(dirname "$WG_CONF")"
  if [[ $DRY_RUN == 0 && ! -d /etc/wireguard ]]; then
    install -d -m 700 /etc/wireguard
  fi
  cat >"$WG_CONF" <<EOF
# Managed by oneday-vpn. Stays up until you run: oneday-vpn down
[Interface]
Address = ${VPN_SERVER_IP}/${VPN_PREFIX}
ListenPort = ${PORT}
PrivateKey = ${SERVER_PRIV}
SaveConfig = false
PostUp = ${STATE_DIR}/postup.sh
PostDown = ${STATE_DIR}/postdown.sh

[Peer]
PublicKey = ${CLIENT_PUB}
PresharedKey = ${PSK}
AllowedIPs = ${VPN_CLIENT_IP}/32
EOF
  chmod 600 "$WG_CONF"
}

client_allowed_ips() {
  if [[ $FULL_TUNNEL == 1 ]]; then
    printf '%s' "0.0.0.0/0, ::/0"
  else
    printf '%s' "${LAN_CIDR}, ${VPN_NET}"
  fi
}

reach_phrase() {
  if [[ $FULL_TUNNEL == 1 ]]; then
    printf '%s' "this network (${LAN_CIDR}) and the internet through this computer"
  else
    printf '%s' "this network (${LAN_CIDR})"
  fi
}

write_client_files() {
  local dest allowed dns_line
  if [[ $DRY_RUN == 1 ]]; then
    dest=$DRY_ROOT/home
  elif [[ -n ${SUDO_USER:-} && $SUDO_USER != root ]]; then
    dest=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    [[ -n $dest && -d $dest ]] || dest=/root
  else
    dest=${HOME:-/root}
  fi
  mkdir -p "$dest"
  CLIENT_CONF_PATH=$dest/oneday-client.conf
  CLIENT_HOWTO_PATH=$dest/oneday-client-howto.txt
  CLIENT_PNG_PATH=$dest/oneday-client.png
  allowed=$(client_allowed_ips)
  if [[ $FULL_TUNNEL == 1 ]]; then
    dns_line=$'DNS = 1.1.1.1\n'
  else
    dns_line=""
  fi
  cat >"$CLIENT_CONF_PATH" <<EOF
# VPN access to this network. Stays up until the server operator turns it off.
# Reaches: $(reach_phrase)
[Interface]
PrivateKey = ${CLIENT_PRIV}
Address = ${VPN_CLIENT_IP}/32
${dns_line}
[Peer]
PublicKey = ${SERVER_PUB}
PresharedKey = ${PSK}
Endpoint = ${ENDPOINT_HOST}:${ENDPOINT_PORT}
AllowedIPs = ${allowed}
PersistentKeepalive = 25
EOF
  chmod 600 "$CLIENT_CONF_PATH"
  cp "$CLIENT_CONF_PATH" "$STATE_DIR/client.conf"
  chmod 600 "$STATE_DIR/client.conf"

  {
    echo "Network access"
    echo
    echo "The file oneday-client.conf is the connection. Treat it like a password."
    echo "It can reach $(reach_phrase)."
    echo "It stays up until the person who runs the server turns it off."
    echo
    echo "1. Install WireGuard."
    echo "   Windows, Mac, and Linux: https://www.wireguard.com/install/"
    echo "   iPhone: WireGuard on the App Store."
    echo "   Android: WireGuard on the Play Store."
    echo
    echo "2. Import oneday-client.conf."
    echo "   Windows or Mac: open WireGuard, choose Add Tunnel, then Import tunnel(s) from file."
    echo "   iPhone or Android: open WireGuard, tap +, then scan the QR code or import the file."
    echo "   Linux: sudo wg-quick up ./oneday-client.conf"
    echo
    echo "3. Turn the tunnel on."
    echo
    echo "4. Check it. In a terminal, run:"
    echo "   ping ${LAN_IP}"
    echo "   Other devices on ${LAN_CIDR} should respond if they allow local network access."
    echo
    echo "5. Turn the tunnel off when the work is done."
    echo
    echo "If WireGuard shows no handshake, UDP ${ENDPOINT_PORT} is not reaching the server."
    echo "If a handshake appears and ping ${LAN_IP} fails, that device is blocking the traffic."
  } >"$CLIENT_HOWTO_PATH"
  chmod 600 "$CLIENT_HOWTO_PATH"

  if command -v qrencode >/dev/null; then
    qrencode -o "$CLIENT_PNG_PATH" <"$CLIENT_CONF_PATH" || true
    [[ -f $CLIENT_PNG_PATH ]] && chmod 600 "$CLIENT_PNG_PATH"
  fi

  if [[ $DRY_RUN == 0 && -n ${SUDO_USER:-} && $SUDO_USER != root ]]; then
    chown "$SUDO_USER" "$CLIENT_CONF_PATH" "$CLIENT_HOWTO_PATH" || true
    if [[ -f $CLIENT_PNG_PATH ]]; then
      chown "$SUDO_USER" "$CLIENT_PNG_PATH" || true
    fi
  fi
}

ufw_insert_nat() {
  local file=$1 rule=$2
  python3 - "$file" "$rule" <<'PY'
import pathlib, sys
path, rule = sys.argv[1], sys.argv[2]
file = pathlib.Path(path)
text = file.read_text() if file.exists() else ""
if "BEGIN ONEDAY-VPN" in text:
    sys.exit(0)
lines = text.splitlines(keepends=True)
inserted = False
for i, line in enumerate(lines):
    if line.strip() == "*nat":
        for j in range(i + 1, len(lines)):
            if lines[j].startswith("COMMIT"):
                lines.insert(j, "# END ONEDAY-VPN\n")
                lines.insert(j, rule + "\n")
                lines.insert(j, "# BEGIN ONEDAY-VPN\n")
                inserted = True
                break
        if not inserted:
            sys.exit("found *nat without COMMIT")
        break
if not inserted:
    block = (
        "# BEGIN ONEDAY-VPN\n"
        "*nat\n"
        ":POSTROUTING ACCEPT [0:0]\n"
        + rule
        + "\nCOMMIT\n"
        "# END ONEDAY-VPN\n"
    )
    lines.insert(0, block)
file.parent.mkdir(parents=True, exist_ok=True)
file.write_text("".join(lines))
PY
}

ufw_remove_nat() {
  local file=$1
  [[ -f $file ]] || return 0
  python3 - "$file" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
text = path.read_text()
begin = "# BEGIN ONEDAY-VPN\n"
end = "# END ONEDAY-VPN\n"
if begin not in text or end not in text:
    sys.exit(0)
pre, rest = text.split(begin, 1)
_, post = rest.split(end, 1)
path.write_text(pre + post)
PY
}

init_undo() {
  printf '%s\n' '#!/bin/bash' 'set +e' >"$STATE_DIR/firewall-undo.sh"
  chmod 700 "$STATE_DIR/firewall-undo.sh"
}

append_undo() {
  printf '%s\n' "$1" >>"$STATE_DIR/firewall-undo.sh"
}

detect_firewall() {
  if [[ $DRY_RUN == 1 ]]; then
    FIREWALL=${ONEDAY_FIREWALL:-iptables}
    return 0
  fi
  FIREWALL=iptables
  if command -v firewall-cmd >/dev/null && firewall-cmd --state >/dev/null 2>&1; then
    FIREWALL=firewalld
    return 0
  fi
  if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q 'Status: active'; then
    FIREWALL=ufw
  fi
}

apply_firewall() {
  local rules dest
  : >"$STATE_DIR/firewall-plan.txt"
  case "$FIREWALL" in
    iptables)
      echo "iptables rules are installed by ${STATE_DIR}/postup.sh" >>"$STATE_DIR/firewall-plan.txt"
      ;;
    ufw)
      rules=$UFW_BEFORE_RULES
      if [[ $DRY_RUN == 1 ]]; then
        rules=$DRY_ROOT/etc/ufw/before.rules
        mkdir -p "$(dirname "$rules")"
        if [[ ! -f $rules ]]; then
          printf '*filter\n:INPUT ACCEPT [0:0]\nCOMMIT\n' >"$rules"
        fi
      fi
      ufw_insert_nat "$rules" "$NAT_RULE"
      append_undo "python3 - <<'PY'
import pathlib
path = pathlib.Path('${rules}')
text = path.read_text() if path.exists() else ''
begin = '# BEGIN ONEDAY-VPN\\n'
end = '# END ONEDAY-VPN\\n'
if begin in text and end in text:
    pre, rest = text.split(begin, 1)
    _, post = rest.split(end, 1)
    path.write_text(pre + post)
PY"
      if [[ $FULL_TUNNEL == 1 ]]; then
        printf 'ufw route allow in on %s out on %s comment oneday-vpn\n' "$IFACE" "$LAN_IF" >>"$STATE_DIR/firewall-plan.txt"
        printf 'ufw route allow in on %s out on %s comment oneday-vpn\n' "$LAN_IF" "$IFACE" >>"$STATE_DIR/firewall-plan.txt"
        append_undo "ufw route delete allow in on ${IFACE} out on ${LAN_IF} || true"
        append_undo "ufw route delete allow in on ${LAN_IF} out on ${IFACE} || true"
      else
        printf 'ufw route allow in on %s out on %s to %s comment oneday-vpn\n' "$IFACE" "$LAN_IF" "$LAN_CIDR" >>"$STATE_DIR/firewall-plan.txt"
        printf 'ufw route allow in on %s out on %s from %s comment oneday-vpn\n' "$LAN_IF" "$IFACE" "$LAN_CIDR" >>"$STATE_DIR/firewall-plan.txt"
        append_undo "ufw route delete allow in on ${IFACE} out on ${LAN_IF} to ${LAN_CIDR} || true"
        append_undo "ufw route delete allow in on ${LAN_IF} out on ${IFACE} from ${LAN_CIDR} || true"
      fi
      printf 'ufw allow in on %s from %s to any comment oneday-vpn\n' "$IFACE" "$VPN_NET" >>"$STATE_DIR/firewall-plan.txt"
      printf 'ufw allow %s/udp comment oneday-vpn\n' "$PORT" >>"$STATE_DIR/firewall-plan.txt"
      append_undo "ufw delete allow in on ${IFACE} from ${VPN_NET} to any || true"
      append_undo "ufw delete allow ${PORT}/udp || true"
      append_undo "ufw reload || true"
      if [[ $DRY_RUN == 0 ]]; then
        if [[ $FULL_TUNNEL == 1 ]]; then
          ufw route allow in on "$IFACE" out on "$LAN_IF" comment oneday-vpn
          ufw route allow in on "$LAN_IF" out on "$IFACE" comment oneday-vpn
        else
          ufw route allow in on "$IFACE" out on "$LAN_IF" to "$LAN_CIDR" comment oneday-vpn
          ufw route allow in on "$LAN_IF" out on "$IFACE" from "$LAN_CIDR" comment oneday-vpn
        fi
        ufw allow in on "$IFACE" from "$VPN_NET" to any comment oneday-vpn
        ufw allow "${PORT}/udp" comment oneday-vpn
        ufw reload
      fi
      ;;
    firewalld)
      dest=$(firewall_zone)
      {
        echo "firewall-cmd --permanent --zone=${dest} --add-port=${PORT}/udp"
        echo "firewall-cmd --permanent --zone=trusted --add-source=${VPN_NET}"
        echo "firewall-cmd --permanent --zone=${dest} --add-masquerade"
        echo "firewall-cmd --reload"
      } >>"$STATE_DIR/firewall-plan.txt"
      if [[ $DRY_RUN == 0 ]]; then
        local added_port=0 added_source=0 added_masq=0
        if ! firewall-cmd --zone="$dest" --query-port="${PORT}/udp" >/dev/null 2>&1; then
          firewall-cmd --permanent --zone="$dest" --add-port="${PORT}/udp"
          added_port=1
        fi
        if ! firewall-cmd --zone=trusted --query-source="$VPN_NET" >/dev/null 2>&1; then
          firewall-cmd --permanent --zone=trusted --add-source="$VPN_NET"
          added_source=1
        fi
        if ! firewall-cmd --zone="$dest" --query-masquerade >/dev/null 2>&1; then
          firewall-cmd --permanent --zone="$dest" --add-masquerade
          added_masq=1
        fi
        firewall-cmd --reload
        [[ $added_port == 1 ]] && append_undo "firewall-cmd --permanent --zone=${dest} --remove-port=${PORT}/udp || true"
        [[ $added_source == 1 ]] && append_undo "firewall-cmd --permanent --zone=trusted --remove-source=${VPN_NET} || true"
        [[ $added_masq == 1 ]] && append_undo "firewall-cmd --permanent --zone=${dest} --remove-masquerade || true"
        append_undo "firewall-cmd --reload || true"
      else
        append_undo "echo firewalld dry-run undo"
      fi
      ;;
    *)
      die "Unknown firewall mode ${FIREWALL}"
      ;;
  esac
}

firewall_zone() {
  local zone=""
  if [[ $DRY_RUN == 1 ]] || ! command -v firewall-cmd >/dev/null; then
    printf '%s' "public"
    return 0
  fi
  zone=$(firewall-cmd --get-zone-of-interface="$LAN_IF" 2>/dev/null | head -n 1 || true)
  if [[ -z $zone || $zone == "no zone" ]]; then
    zone=$(firewall-cmd --get-default-zone)
  fi
  printf '%s' "$zone"
}

enable_forwarding() {
  if [[ $DRY_RUN == 0 ]]; then
    IP_FORWARD_PREV=$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo 0)
    RP_ALL_PREV=$(sysctl -n net.ipv4.conf.all.rp_filter 2>/dev/null || echo "")
    RP_LAN_PREV=$(sysctl -n "net.ipv4.conf.${LAN_IF}.rp_filter" 2>/dev/null || echo "")
  else
    IP_FORWARD_PREV=0
    RP_ALL_PREV=1
    RP_LAN_PREV=1
  fi
  mkdir -p "$(dirname "$SYSCTL_FILE")"
  {
    echo "net.ipv4.ip_forward=1"
    echo "net.ipv4.conf.all.rp_filter=2"
    if [[ $LAN_IF != *.* && $LAN_IF != *:* ]]; then
      echo "net.ipv4.conf.${LAN_IF}.rp_filter=2"
    fi
  } >"$SYSCTL_FILE"
  if [[ $DRY_RUN == 0 ]]; then
    sysctl -w net.ipv4.ip_forward=1 >/dev/null
    sysctl -w net.ipv4.conf.all.rp_filter=2 >/dev/null || true
    if [[ $LAN_IF != *.* && $LAN_IF != *:* ]]; then
      sysctl -w "net.ipv4.conf.${LAN_IF}.rp_filter=2" >/dev/null || true
    fi
  fi
}

install_helper_script() {
  [[ $DRY_RUN == 1 ]] && return 0
  mkdir -p /usr/local/sbin
  local dest=/usr/local/sbin/oneday-vpn
  if [[ $SCRIPT_PATH != "$dest" ]]; then
    cp "$SCRIPT_PATH" "${dest}.new"
    chmod 0755 "${dest}.new"
    mv -f "${dest}.new" "$dest"
  fi
}

start_wireguard() {
  if [[ $DRY_RUN == 1 ]]; then
    return 0
  fi
  [[ -e /dev/net/tun ]] || die "This computer has no /dev/net/tun, so WireGuard cannot start"
  modprobe tun 2>/dev/null || true
  modprobe wireguard 2>/dev/null || true
  if ip link show "$IFACE" >/dev/null 2>&1; then
    die "Interface ${IFACE} already exists. Run 'sudo ${SCRIPT_PATH} down' and try again"
  fi
  if have_systemd; then
    systemctl enable --now "wg-quick@${IFACE}"
  else
    wg-quick up "$IFACE"
    echo "This computer has no systemd. A reboot stops the tunnel until you run: sudo wg-quick up ${IFACE}"
  fi
}

need_port_forward() {
  NEED_FORWARD=0
  if is_private_or_cgnat "$LAN_IP"; then
    NEED_FORWARD=1
  fi
  if [[ $ENDPOINT_HOST == "$LAN_IP" ]]; then
    NEED_FORWARD=0
  fi
}

print_card() {
  local allowed
  allowed=$(client_allowed_ips)
  echo
  echo "============================================================"
  if [[ $DRY_RUN == 1 ]]; then
    echo "Dry run only. No VPN was started."
  else
    echo "VPN is up."
  fi
  if [[ $PLACEHOLDER_ENDPOINT == 1 || $PLACEHOLDER_LAN == 1 ]]; then
    echo "Some addresses below are examples. Pass the real LAN and endpoint to see a real card."
  fi
  echo "Stays up until you run: sudo oneday-vpn down"
  echo "Endpoint:    ${ENDPOINT_HOST}:${ENDPOINT_PORT}"
  echo "Client file:  ${CLIENT_CONF_PATH}"
  echo "Instructions: ${CLIENT_HOWTO_PATH}"
  if [[ $PLACEHOLDER_ENDPOINT == 1 ]]; then
    echo
    echo "This endpoint is a placeholder, not a reachable address."
    echo "On the real computer the script prints that computer's public IP."
  elif [[ $NEED_FORWARD == 1 ]]; then
    echo
    echo "On the router, forward UDP ${ENDPOINT_PORT} to ${LAN_IP}."
    if [[ -n ${GATEWAY:-} ]]; then
      echo "The router is usually at http://${GATEWAY}/"
    fi
    echo "External port ${ENDPOINT_PORT}, internal address ${LAN_IP}, protocol UDP."
    echo "The client's config uses ${ENDPOINT_HOST}:${ENDPOINT_PORT}."
  else
    echo
    echo "No router port forward is required. UDP ${ENDPOINT_PORT} must be allowed on this computer."
  fi
  if [[ $FULL_TUNNEL == 1 ]]; then
    echo
    echo "Full tunnel: all of the client's internet traffic goes through this computer."
  else
    echo
    echo "Split tunnel: the client reaches ${LAN_CIDR} and keeps their own internet."
  fi
  if [[ $LAN_CIDR == */32 ]]; then
    echo "This subnet is a single address, so the client can reach ${LAN_IP} only."
    echo "If the LAN is larger, run setup again with --replace --lan-cidr 192.168.0.0/24"
  fi
  echo
  echo "Send ${CLIENT_CONF_PATH} and ${CLIENT_HOWTO_PATH} through a private chat."
  echo "To turn it off: sudo oneday-vpn down"
  echo "To see if the client connected: sudo oneday-vpn status"
  echo "AllowedIPs in the client file: ${allowed}"
  echo "============================================================"
  if command -v qrencode >/dev/null && [[ -t 1 || $DRY_RUN == 1 ]]; then
    echo
    echo "QR code for the WireGuard phone app:"
    qrencode -t ANSIUTF8 <"$CLIENT_CONF_PATH" || true
  elif [[ ! -f ${CLIENT_PNG_PATH:-} ]]; then
    echo "Install qrencode if you want a QR code for a phone."
  fi
  echo
  echo "----- client config (this private key is the connection) -----"
  cat "$CLIENT_CONF_PATH"
  echo "----- end client config -----"
}

setup_failed() {
  local code=$?
  trap - ERR INT TERM
  [[ ${SETUP_READY:-0} == 1 ]] || exit "$code"
  echo "Setup failed (exit ${code}). Removing the partial VPN." >&2
  echo "If WireGuard reported a missing module, reboot into a kernel that includes WireGuard, or run tailscale mode." >&2
  cmd_down --quiet || true
  exit "$code"
}

cmd_setup() {
  require_root
  if [[ $REPLACE == 1 && $DRY_RUN == 0 ]]; then
    cmd_down --quiet || true
  fi
  if [[ $DRY_RUN == 0 && -f $STATE_DIR/state.env && $REPLACE != 1 ]]; then
    die "A one-day VPN is already configured. Run 'sudo ${SCRIPT_PATH} down' or add --replace"
  fi
  ensure_basics
  detect_lan
  resolve_endpoint
  refuse_if_unreachable
  [[ $DRY_RUN == 1 ]] || install_packages
  choose_port
  choose_vpn_net
  validate_token "interface" "$LAN_IF"
  validate_token "vpn" "$VPN_NET"
  prepare_dirs
  if [[ $DRY_RUN == 0 ]]; then
    SETUP_READY=1
    trap setup_failed ERR INT TERM
  fi
  init_undo
  detect_firewall
  gen_material
  enable_forwarding
  write_hook_scripts
  write_server_conf
  MODE=wireguard
  need_port_forward
  write_client_files
  write_state
  apply_firewall
  install_helper_script
  start_wireguard
  if [[ $DRY_RUN == 0 ]]; then
    trap - ERR INT TERM
  fi
  log_msg "wireguard up endpoint=${ENDPOINT_HOST}:${ENDPOINT_PORT} lan=${LAN_CIDR}"
  print_card
}

load_state() {
  if [[ -f $STATE_DIR/state.env ]]; then
    # shellcheck disable=SC1090,SC1091
    source "$STATE_DIR/state.env"
    return 0
  fi
  return 1
}

destroy_file() {
  local f=$1
  [[ -n $f && -f $f ]] || return 0
  if command -v shred >/dev/null; then
    shred -u "$f" 2>/dev/null || rm -f "$f"
  else
    rm -f "$f"
  fi
}

cancel_auto_shutdown() {
  # Older builds scheduled `down --expired`. Leave the tunnel up and drop that timer.
  [[ $DRY_RUN == 1 ]] && return 0
  require_root
  trap - ERR INT TERM
  set +e
  if have_systemd; then
    systemctl disable --now oneday-vpn-expire.timer >/dev/null 2>&1 || true
  fi
  rm -f "$UNIT_DIR/oneday-vpn-expire.timer" "$UNIT_DIR/oneday-vpn-expire.service"
  if have_systemd; then
    systemctl daemon-reload >/dev/null 2>&1 || true
  fi
  if [[ -f ${STATE_DIR}/sleeper.pid ]]; then
    local pid
    pid=$(cat "$STATE_DIR/sleeper.pid" 2>/dev/null || true)
    if [[ -n ${pid:-} && $pid != "$$" && $pid != "$PPID" ]]; then
      kill "$pid" 2>/dev/null || true
    fi
    rm -f "$STATE_DIR/sleeper.pid"
  fi
  # Replace an older installed copy that still treats --expired as a full shutdown.
  install_helper_script || true
  echo "Automatic shutdown is off. The VPN stays up until you run: sudo oneday-vpn down"
  set -e
  return 0
}

cmd_down() {
  # Flags may already have been parsed by main. Accept a direct --quiet too.
  if [[ ${1:-} == --quiet ]]; then
    QUIET=1
  fi
  if [[ $EXPIRED == 1 ]]; then
    cancel_auto_shutdown
    return 0
  fi
  trap - ERR INT TERM
  set +e
  if [[ $DRY_RUN == 1 ]]; then
    rm -rf "${DRY_ROOT:-$PWD/dry-run-out}"
    set -e
    return 0
  fi
  require_root
  local had_state=0
  if load_state; then
    had_state=1
  fi
  if [[ -f ${STATE_DIR}/sleeper.pid ]]; then
    local pid
    pid=$(cat "$STATE_DIR/sleeper.pid" 2>/dev/null || true)
    if [[ -n ${pid:-} && $pid != "$$" && $pid != "$PPID" ]]; then
      kill "$pid" 2>/dev/null || true
    fi
  fi
  if have_systemd; then
    systemctl disable --now oneday-vpn-expire.timer >/dev/null 2>&1 || true
    systemctl disable --now "wg-quick@${IFACE}" >/dev/null 2>&1 || true
  fi
  if command -v ip >/dev/null && ip link show "$IFACE" >/dev/null 2>&1; then
    wg-quick down "$IFACE" >/dev/null 2>&1 || true
  fi
  rm -f "$UNIT_DIR/oneday-vpn-expire.timer" "$UNIT_DIR/oneday-vpn-expire.service"
  if have_systemd; then
    systemctl daemon-reload >/dev/null 2>&1 || true
  fi
  rm -f "$WG_CONF"
  if [[ -x ${STATE_DIR}/firewall-undo.sh ]]; then
    bash "$STATE_DIR/firewall-undo.sh" >/dev/null 2>&1 || true
  fi
  if [[ ${MODE:-} == tailscale ]] && command -v tailscale >/dev/null; then
    tailscale set --advertise-routes="${OLD_ROUTES:-}" >/dev/null 2>&1 || true
    if [[ ${TAILSCALE_PREEXISTING:-0} == 0 ]]; then
      tailscale down >/dev/null 2>&1 || true
    fi
  fi
  if [[ -n ${IP_FORWARD_PREV:-} && ${IP_FORWARD_PREV} == 0 ]]; then
    if ! iptables -nL DOCKER-USER >/dev/null 2>&1; then
      sysctl -w net.ipv4.ip_forward=0 >/dev/null 2>&1 || true
    fi
  fi
  if [[ -n ${RP_ALL_PREV:-} ]]; then
    sysctl -w "net.ipv4.conf.all.rp_filter=${RP_ALL_PREV}" >/dev/null 2>&1 || true
  fi
  if [[ -n ${RP_LAN_PREV:-} && -n ${LAN_IF:-} ]]; then
    sysctl -w "net.ipv4.conf.${LAN_IF}.rp_filter=${RP_LAN_PREV}" >/dev/null 2>&1 || true
  fi
  rm -f "$SYSCTL_FILE"
  destroy_file "${CLIENT_CONF_PATH:-}"
  destroy_file "${CLIENT_PNG_PATH:-}"
  destroy_file "$STATE_DIR/client.conf"
  rm -rf "$STATE_DIR"
  log_msg "down"
  if [[ $QUIET == 0 ]]; then
    if [[ $had_state == 1 ]]; then
      echo "The VPN is off. The client can no longer connect."
    else
      echo "No VPN was configured. Leftover interface and timer were cleaned up."
    fi
  fi
  set -e
  return 0
}

cmd_status() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    if [[ -r $HOME/oneday-client-howto.txt ]]; then
      echo "Client instructions: $HOME/oneday-client-howto.txt"
      echo "Run sudo oneday-vpn status to see the tunnel."
      exit 0
    fi
    die "Run as root: sudo oneday-vpn status"
  fi
  if ! load_state; then
    echo "No VPN is configured."
    exit 0
  fi
  echo "Mode:    ${MODE:-unknown}"
  echo "Stays up until you run: sudo oneday-vpn down"
  if [[ ${MODE:-} == wireguard ]]; then
    echo "Endpoint: ${ENDPOINT_HOST:-}:${ENDPOINT_PORT:-}"
    echo "LAN:      ${LAN_CIDR:-} via ${LAN_IF:-} (${LAN_IP:-})"
    if command -v wg >/dev/null && command -v ip >/dev/null && ip link show "$IFACE" >/dev/null 2>&1; then
      echo "Tunnel:   up"
      wg show "$IFACE"
    else
      echo "Tunnel:   down"
      echo "Start it again with: sudo systemctl start wg-quick@${IFACE}"
    fi
  elif [[ ${MODE:-} == tailscale ]]; then
    echo "Advertised route: ${LAN_CIDR:-}"
    if command -v tailscale >/dev/null; then
      tailscale status || true
    fi
  fi
  [[ -n ${CLIENT_CONF_PATH:-} ]] && echo "Client file: ${CLIENT_CONF_PATH}"
}

cmd_show() {
  local f
  for f in "${HOME:-}/oneday-client.conf" /root/oneday-client.conf "$STATE_DIR/client.conf"; do
    if [[ -n $f && -r $f ]]; then
      cat "$f"
      return 0
    fi
  done
  die "No client config is waiting. Run setup on the server first."
}

capture_old_routes() {
  OLD_ROUTES=""
  TAILSCALE_PREEXISTING=0
  if command -v tailscale >/dev/null && tailscale status >/dev/null 2>&1; then
    TAILSCALE_PREEXISTING=1
    OLD_ROUTES=$(tailscale debug prefs 2>/dev/null | python3 -c 'import json,sys
try:
    data=json.load(sys.stdin)
except Exception:
    data={}
routes=data.get("AdvertiseRoutes") or []
print(",".join(str(r) for r in routes))
' || true)
  fi
}

cmd_tailscale() {
  require_root
  if [[ $DRY_RUN == 0 && -f $STATE_DIR/state.env && $REPLACE != 1 ]]; then
    die "A one-day VPN is already configured. Run 'sudo ${SCRIPT_PATH} down' or add --replace"
  fi
  if [[ $REPLACE == 1 && $DRY_RUN == 0 ]]; then
    cmd_down --quiet || true
  fi
  ensure_basics
  detect_lan
  if [[ $DRY_RUN == 1 ]]; then
    prepare_dirs
    MODE=tailscale
    ENDPOINT_HOST="tailscale"
    ENDPOINT_PORT="41641"
    NEED_FORWARD=0
    FIREWALL=tailscale
    CLIENT_CONF_PATH=""
    write_state
    cat <<EOF
Dry run only. No Tailscale login was started.
On the real computer this installs Tailscale and advertises ${LAN_CIDR}.
The route stays up until you run: sudo oneday-vpn down
EOF
    return 0
  fi

  if ! command -v tailscale >/dev/null; then
    curl -fsSL https://tailscale.com/install.sh | sh
  fi
  command -v tailscale >/dev/null || die "Tailscale did not install"
  capture_old_routes
  prepare_dirs
  SETUP_READY=1
  trap setup_failed ERR INT TERM
  enable_forwarding
  MODE=tailscale
  VPN_NET=""
  ENDPOINT_HOST="tailscale"
  ENDPOINT_PORT="41641"
  NEED_FORWARD=0
  FIREWALL=tailscale
  CLIENT_CONF_PATH=""
  CLIENT_HOWTO_PATH=""
  CLIENT_PNG_PATH=""
  init_undo
  write_state
  install_helper_script
  local -a args
  args=(tailscale up --advertise-routes="$LAN_CIDR" --snat-subnet-routes=true --accept-dns=false --ssh=false --hostname=oneday-vpn)
  if [[ -n ${SUDO_USER:-} && $SUDO_USER != root ]]; then
    args+=(--operator="$SUDO_USER")
  fi
  cat <<EOF

Tailscale will print a login URL. Open it and sign in.
Then open https://login.tailscale.com/admin/machines
and approve the route ${LAN_CIDR} for hostname oneday-vpn.

The client installs Tailscale from https://tailscale.com/download
and signs in with the same account, then turns Tailscale on.
They can reach ${LAN_CIDR}. This computer is ${LAN_IP}.

The route stays up until you run: sudo oneday-vpn down
EOF
  echo
  "${args[@]}"
  trap - ERR INT TERM
  log_msg "tailscale advertising ${LAN_CIDR}"
  echo "Tailscale is up. Approve ${LAN_CIDR} in the admin console if it is still pending."
}

main() {
  umask 077
  set -E
  parse_args "$@"
  case "$CMD" in
    ""|help)
      usage
      ;;
    setup|up)
      cmd_setup
      ;;
    down|revoke)
      cmd_down
      ;;
    status)
      cmd_status
      ;;
    show)
      cmd_show
      ;;
    tailscale)
      cmd_tailscale
      ;;
    *)
      die "Unknown command ${CMD}"
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
