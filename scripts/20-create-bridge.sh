#!/usr/bin/env bash
# Bridge the PXE NIC so the FOG guest can sit on the same L2 as PXE clients.
# The host keeps its PXE-segment IP on the bridge; no default route leaks onto it.
# Assumes NetworkManager (Debian/Ubuntu default). Safe: run this from a shell on
# UPLINK_IFACE — never over PXE_IFACE, which this reconfigures.
. "$(dirname "$0")/lib.sh"; load_config
need nmcli
PREFIX="$(prefix_from_netmask "$PXE_NETMASK")"

if nmcli -t -f NAME con show | grep -qx "$BRIDGE"; then
  warn "Bridge connection '$BRIDGE' already exists — skipping creation."
else
  msg "Creating bridge $BRIDGE ($AWB_HOST_IP/$PREFIX) with $PXE_IFACE enslaved"
  sudo nmcli con add type bridge con-name "$BRIDGE" ifname "$BRIDGE" \
       ipv4.method manual ipv4.addresses "$AWB_HOST_IP/$PREFIX" \
       ipv4.never-default yes ipv6.method disabled bridge.stp no
  sudo nmcli con add type ethernet con-name "$BRIDGE-$PXE_IFACE" ifname "$PXE_IFACE" master "$BRIDGE"
  # stop the old PXE_IFACE profile from reclaiming the address
  sudo nmcli con mod "$PXE_IFACE" connection.autoconnect no 2>/dev/null || true
  sudo nmcli con down "$PXE_IFACE" 2>/dev/null || true
  sudo nmcli con up "$BRIDGE"
  sudo nmcli con up "$BRIDGE-$PXE_IFACE"
fi

msg "Point your DHCP server at the bridge. For isc-dhcp-server:"
echo "    INTERFACESv4=\"$BRIDGE\"   in /etc/default/isc-dhcp-server, then restart it."
msg "Result:"; ip -br addr show "$BRIDGE" | sed 's/^/    /'
msg "Done. Next: ./30-provision-fog-vm.sh"
