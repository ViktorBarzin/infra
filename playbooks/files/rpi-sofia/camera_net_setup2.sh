#!/usr/bin/env bash
# exec > /home/pi/vermont_cameras/log.txt 2>&1

set -euxo pipefail

### ============================
### CONFIG
### ============================
NS_NAME="guestns"
GUEST_ETH="eth0"   # was eth0 (built-in Eth, renamed by systemd predictable naming 2026-04-27)
GUEST_ETH_IP="192.168.1.2/24"
GUEST_SUBNET_CIDR="192.168.1.0/24"

HOST_VETH="veth-host"
GUEST_VETH="veth-guest"
HOST_VETH_IP="10.200.1.1/24"
GUEST_VETH_IP="10.200.1.2/24"

WAN_IF="eth1"      # was eth1 (USB-Eth Realtek, renamed 2026-04-27)

# (WAN_PORT PROTO TARGET_IP TARGET_PORT)
PORTS=(
  "8080 tcp 192.168.1.150 81" # .1.150 -> NVR
  "8080 udp 192.168.1.150 81"
  "8000 tcp 192.168.1.150 8000"
  "8000 udp 192.168.1.150 8000"
  "554 tcp 192.168.1.150 554"
  "554 udp 192.168.1.150 554"
  # Solar panel (port 80 is the router in front, 8899 is panel port)
  "8081 tcp 192.168.1.201 80"
  #"8899 tcp 192.168.1.203 8899"
  #"8899 tcp 192.168.1.203 8899"
  "8082 tcp 192.168.1.202 80"

  "8083 tcp 192.168.1.203 80" 
  "38899 tcp 192.168.1.203 8899" 
  "38080 tcp 192.168.1.203 8080" 

  "8084 tcp 192.168.1.204 80" 

  # "5000 tcp 192.168.1.112 80" # -> security panels
  # "5001 tcp 192.168.1.112 8000"
)

### ============================
### HELPERS
### ============================
wait_for_internet() {
  echo "[+] Waiting for internet connectivity..."
  local max_attempts=300   # 30 tries
  local attempt=1
  while ! ping -c 1 -W 1 1.1.1.1 &>/dev/null; do
    echo "Attempt $attempt/$max_attempts: no internet yet..."
    attempt=$((attempt + 1))
    if [ "$attempt" -gt "$max_attempts" ]; then
      echo "ERROR: Internet did not appear after $max_attempts attempts" >&2
      exit 1
    fi
    sleep 2
  done
  echo "[+] Internet connectivity detected."
}

ipt_add_once() {
  # usage: ipt_add_once -t nat -A PREROUTING ... (exact rule after options)
  if ! sudo iptables "$@" -C 2>/dev/null; then
    sudo iptables "$@" -A
  fi
}

ns_ipt_add_once_raw() {
  local ns="$1"; shift
  local table="$1"; shift
  local chain="$1"; shift
  if ! sudo ip netns exec "$ns" iptables -t "$table" -C "$chain" "$@" 2>/dev/null; then
    sudo ip netns exec "$ns" iptables -t "$table" -A "$chain" "$@"
  else
    echo Rule already exists in: $ns for -t $table -C $chain $@ 
  fi
}
ns_ipt_del_if_exists_raw() {
  local ns="$1"; shift
  local table="$1"; shift
  local chain="$1"; shift
  if sudo ip netns exec "$ns" iptables -t "$table" -C "$chain" "$@" 2>/dev/null; then
    sudo ip netns exec "$ns" iptables -t "$table" -D "$chain" "$@"
  fi
}

ipt_add_once_raw() {
  # When -C expects the whole rule, pass chain separately:
  # usage: ipt_add_once_raw "nat" "PREROUTING" args...
  local table="$1"; shift
  local chain="$1"; shift
  if ! sudo iptables -t "$table" -C "$chain" "$@" 2>/dev/null; then
    sudo iptables -t "$table" -A "$chain" "$@"
  else
    echo Rule already exists: -t $table -C $chain $@ 
  fi
}
ipt_del_if_exists_raw() {
  local table="$1"; shift
  local chain="$1"; shift
  if sudo iptables -t "$table" -C "$chain" "$@" 2>/dev/null; then
    sudo iptables -t "$table" -D "$chain" "$@"
  fi
}

has_link() { ip link show "$1" &>/dev/null; }
ns_has_link() { sudo ip netns exec "$1" ip link show "$2" &>/dev/null; }
addr_assigned() { ip -o addr show dev "$1" | grep -qw "${2%/*}"; }
ns_addr_assigned() { sudo ip netns exec "$1" ip -o addr show dev "$2" | grep -qw "${3%/*}"; }

### ============================
### 1) INTERFACE SETUP
### ============================
create_ns_and_move_eth() {
  # Create namespace
  if ! ip netns list | grep -qw "$NS_NAME"; then
    sudo ip netns add "$NS_NAME"
  else
    echo Interface $NS_NAME already exists
  fi

  # Move eth0 into ns (only if still in host)
  if has_link "$GUEST_ETH"; then
    sudo ip link set "$GUEST_ETH" netns "$NS_NAME"
  else
    echo Interface $GUEST_ETH already exists in $NS_NAME
  fi

  # Configure eth0 inside ns
  if ns_has_link "$NS_NAME" "$GUEST_ETH"; then
    if ! ns_addr_assigned "$NS_NAME" "$GUEST_ETH" "$GUEST_ETH_IP"; then
      sudo ip netns exec "$NS_NAME" ip addr add "$GUEST_ETH_IP" dev "$GUEST_ETH"
    fi
    sudo ip netns exec "$NS_NAME" ip link set "$GUEST_ETH" up
  else
    echo "ERROR: $GUEST_ETH not present in namespace $NS_NAME" >&2
    exit 1
  fi
}

create_veth_and_ips() {
  # Create veth pair if host side missing
  if ! has_link "$HOST_VETH"; then
    sudo ip link add "$HOST_VETH" type veth peer name "$GUEST_VETH"
    sudo ip link set "$GUEST_VETH" netns "$NS_NAME"
  else
    echo veth interface $HOST_VETH already exists
  fi

  # Host veth config
  if ! addr_assigned "$HOST_VETH" "$HOST_VETH_IP"; then
    sudo ip addr add "$HOST_VETH_IP" dev "$HOST_VETH" || true
  else
    echo $HOST_VETH already has $HOST_VETH_IP assigned
  fi
  sudo ip link set "$HOST_VETH" up

  # Guest veth config
  if ! ns_addr_assigned "$NS_NAME" "$GUEST_VETH" "$GUEST_VETH_IP"; then
    sudo ip netns exec "$NS_NAME" ip addr add "$GUEST_VETH_IP" dev "$GUEST_VETH" || true
  else
    echo $GUEST_VETH already has $GUEST_VETH_IP assigned
  fi
  sudo ip netns exec "$NS_NAME" ip link set "$GUEST_VETH" up

  # Default route in guest ns -> host veth
  sudo ip netns exec "$NS_NAME" ip route replace default via "${HOST_VETH_IP%/*}"
}

### ============================
### 2) IPTABLES & FIREWALL CONFIGS
### ============================
firewall_host_side() {
  # setup NAT (guest -> internet via wlan0)
  ipt_add_once_raw nat POSTROUTING -s "$GUEST_SUBNET_CIDR" -o "$WAN_IF" -j MASQUERADE

  # Forward traffic guest -> internet
  ipt_add_once_raw filter FORWARD -i "$HOST_VETH" -o "$WAN_IF" -j ACCEPT
  ipt_add_once_raw filter FORWARD -i "$WAN_IF" -o "$HOST_VETH" -m state --state RELATED,ESTABLISHED -j ACCEPT

  # Allow forwarding all traffic to guest ns (as in your script)
  ipt_add_once_raw filter FORWARD -i "$WAN_IF" -o "$HOST_VETH" -j ACCEPT
  ipt_add_once_raw filter FORWARD -i "$HOST_VETH" -o "$WAN_IF" -m state --state RELATED,ESTABLISHED -j ACCEPT

  # These two were duplicated in your script; we keep a single copy idempotently.
  ipt_add_once_raw nat POSTROUTING -o "$HOST_VETH" -j MASQUERADE
}

firewall_host_side_del() {
  ipt_del_if_exists_raw nat POSTROUTING -s "$GUEST_SUBNET_CIDR" -o "$WAN_IF" -j MASQUERADE
  ipt_del_if_exists_raw filter FORWARD -i "$HOST_VETH" -o "$WAN_IF" -j ACCEPT
  ipt_del_if_exists_raw filter FORWARD -i "$WAN_IF" -o "$HOST_VETH" -m state --state RELATED,ESTABLISHED -j ACCEPT
  ipt_del_if_exists_raw filter FORWARD -i "$WAN_IF" -o "$HOST_VETH" -j ACCEPT
  ipt_del_if_exists_raw filter FORWARD -i "$HOST_VETH" -o "$WAN_IF" -m state --state RELATED,ESTABLISHED -j ACCEPT
  ipt_del_if_exists_raw nat POSTROUTING -o "$HOST_VETH" -j MASQUERADE
}

firewall_guest_ns_side() {
  # Masquerade traffic from lan -> guest (inside ns) out eth0
  ns_ipt_add_once_raw "$NS_NAME" nat POSTROUTING -o "$GUEST_ETH" -j MASQUERADE

  # Masquerade inside ns out veth-guest (as in your script)
  ns_ipt_add_once_raw "$NS_NAME" nat POSTROUTING -o "$GUEST_VETH" -j MASQUERADE
}

firewall_guest_side_del() {
  ns_ipt_del_if_exists_raw "$NS_NAME" nat POSTROUTING -o "$GUEST_ETH" -j MASQUERADE
  ns_ipt_del_if_exists_raw "$NS_NAME" nat POSTROUTING -o "$GUEST_VETH" -j MASQUERADE
}

### ============================
### 3) PORT FORWARDING (parameterized)
### 2-stage DNAT: wlan0 -> 10.200.1.2:$WAN_PORT -> 192.168.1.x:$TARGET_PORT
### ============================
port_forwarding() {
  local guest_veth_ip="${GUEST_VETH_IP%/*}"
  for mapping in "${PORTS[@]}"; do
    set -- $mapping
    local WAN_PORT="$1" PROTO="$2" TARGET_IP="$3" TARGET_PORT="$4"

    # Host DNAT: wlan0:WAN_PORT -> guest veth IP:WAN_PORT
    ipt_add_once_raw nat PREROUTING -i "$WAN_IF" -p "$PROTO" --dport "$WAN_PORT" \
      -j DNAT --to-destination "${guest_veth_ip}:${WAN_PORT}"

    # Guest ns DNAT: veth-guest:WAN_PORT -> target device:TARGET_PORT
    ns_ipt_add_once_raw "$NS_NAME" nat PREROUTING -i "$GUEST_VETH" -p "$PROTO" --dport "$WAN_PORT" -j DNAT --to-destination "${TARGET_IP}:${TARGET_PORT}"
  done
}
port_forwarding_del() {
  local guest_veth_ip="${GUEST_VETH_IP%/*}"
  for mapping in "${PORTS[@]}"; do
    set -- $mapping
    local WAN_PORT="$1" PROTO="$2" TARGET_IP="$3" TARGET_PORT="$4"
    ipt_del_if_exists_raw nat PREROUTING -i "$WAN_IF" -p "$PROTO" --dport "$WAN_PORT" \
      -j DNAT --to-destination "${guest_veth_ip}:${WAN_PORT}"
    ns_ipt_del_if_exists_raw "$NS_NAME" nat PREROUTING -i "$GUEST_VETH" -p "$PROTO" --dport "$WAN_PORT" \
      -j DNAT --to-destination "${TARGET_IP}:${TARGET_PORT}"
  done
}


### ============================
### MAIN
### ============================
cmd="${1:-setup}"
case "$cmd" in
  setup)
    wait_for_internet
    create_ns_and_move_eth
    create_veth_and_ips
    sudo sysctl -w net.ipv4.ip_forward=1   # main-ns forwarding for camera DNAT (was implicitly set by Docker; fixed 2026-06-05)
    sudo ip netns exec "$NS_NAME" sysctl -w net.ipv4.ip_forward=1
    firewall_guest_ns_side
    firewall_host_side
    port_forwarding
    echo "Done with setup!"
    ;;
  cleanup)
    port_forwarding_del || true
    firewall_guest_side_del || true
    firewall_host_side_del || true
    ip netns list | grep -qw "$NS_NAME" && sudo ip netns del "$NS_NAME" || true
    has_link "$HOST_VETH" && sudo ip link del "$HOST_VETH" || true
    echo "Done with cleanup!"
    ;;
    # echo "[!] Cleanup only removes links (not flushing all iptables to avoid surprises)."
    # ip netns list | grep -qw "$NS_NAME" && sudo ip netns del "$NS_NAME" || true
    # has_link "$HOST_VETH" && sudo ip link del "$HOST_VETH" || true
    # ;;
  *)
    echo "Usage: $0 [setup|cleanup]"
    exit 1
    ;;
esac
# Limit download speed
#sudo tc qdisc add dev veth-host root tbf rate 1mbit burst 32kbit latency 400ms

exit 0

########################################

# sudo ip netns add guestns
# sudo ip netns ls

# # move eth0 to ns
# sudo ip link set eth0 netns guestns
# sudo ip netns exec guestns ip addr add 192.168.1.1/24 dev eth0
# sudo ip netns exec guestns ip link set eth0 up
# sudo ip netns exec guestns ifconfig
# # Masquerade traffic from lan -> guest
# sudo ip netns exec guestns sudo iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE

# # Create a veth pair to connect host ↔ guest
# sudo ip link add veth-host type veth peer name veth-guest
# sudo ip link set veth-guest netns guestns
# # Host namespace
# sudo ip addr add 10.200.1.1/24 dev veth-host
# sudo ip link set veth-host up
# # Guest namespace
# sudo ip netns exec guestns ip addr add 10.200.1.2/24 dev veth-guest
# sudo ip netns exec guestns ip link set veth-guest up
# sudo ip netns exec guestns sudo iptables -t nat -A POSTROUTING -o veth-guest -j MASQUERADE
# # Default route in guest ns
# sudo ip netns exec guestns ip route add default via 10.200.1.1

# # setup NAT
# sudo iptables -t nat -A POSTROUTING -s 192.168.1.0/24 -o wlan0 -j MASQUERADE
# # Forward traffic guest -> internet
# sudo iptables -A FORWARD -i veth-host -o wlan0 -j ACCEPT
# sudo iptables -A FORWARD -i wlan0 -o veth-host -m state --state RELATED,ESTABLISHED -j ACCEPT
# # Drop traffic guest -> LAN
# #sudo iptables -A FORWARD -i veth-host -d 192.168.0.0/16 -j DROP
# #sudo iptables -A FORWARD -i veth-host -d 10.0.0.0/8 -j DROP
# #sudo iptables -A FORWARD -i veth-host -d 172.16.0.0/12 -j DROP

# # Allow forwarding all traffic to gues ns
# sudo iptables -A FORWARD -i wlan0 -o veth-host -j ACCEPT
# sudo iptables -A FORWARD -i veth-host -o wlan0 -m state --state RELATED,ESTABLISHED -j ACCEPT

# sudo iptables -t nat -A POSTROUTING -o veth-host -j MASQUERADE
# sudo iptables -t nat -A POSTROUTING -o veth-host -j MASQUERADE

# # Open ports
# sudo iptables -t nat -A PREROUTING -i wlan0 -p tcp  --dport 8080 -j DNAT --to-destination 10.200.1.2:8080
# sudo ip netns exec guestns  iptables -t nat -A PREROUTING -i veth-guest -p tcp --dport 8080 -j DNAT --to-destination 192.168.1.150:81
# sudo ip netns exec guestns  iptables -t nat -A PREROUTING -i veth-guest -p udp --dport 8080 -j DNAT --to-destination 192.168.1.150:81


# sudo iptables -t nat -A PREROUTING -i wlan0 -p tcp  --dport 8000 -j DNAT --to-destination 10.200.1.2:8000
# sudo ip netns exec guestns  iptables -t nat -A PREROUTING -i veth-guest -p tcp --dport 8000 -j DNAT --to-destination 192.168.1.150:8000
# sudo ip netns exec guestns  iptables -t nat -A PREROUTING -i veth-guest -p udp --dport 8000 -j DNAT --to-destination 192.168.1.150:8000
