#!/usr/bin/env bash
# Bridge the PXE NIC so the FOG guest can sit on the same L2 as PXE clients.
# The host keeps its PXE-segment IP on the bridge; no default route leaks onto it.
# Assumes NetworkManager (Debian/Ubuntu default). Safe: run this from a shell on
# UPLINK_IFACE — never over PXE_IFACE, which this reconfigures.
. "$(dirname "$0")/lib.sh"; load_config
need nmcli
PREFIX="$(prefix_from_netmask "$PXE_NETMASK")"

# --- neutralise /etc/network/interfaces ---------------------------------------
# NetworkManager on Debian/Ubuntu often runs with plugins=ifupdown. Any stanza in
# /etc/network/interfaces is then REGENERATED as an NM connection profile on every
# boot and activated - which pulls PXE_IFACE straight back out of the bridge and
# duplicates the bridge's address. Deleting the generated profile does not help:
# it returns after the next reboot with a NEW UUID.
#
# This is a latent failure. Everything works until the first reboot, and then
# dhcpd refuses to start with "Multiple interfaces match the same subnet" /
# "Not configured to listen on any interfaces!" and PXE clients get nothing.
ENI=/etc/network/interfaces
if [ -f "$ENI" ] && grep -qE "^\s*(auto|allow-hotplug|iface)\s+${PXE_IFACE}\b" "$ENI"; then
  warn "$ENI has a stanza for $PXE_IFACE — it would fight the bridge on every boot."
  backup="$ENI.bak.$(date +%s)"
  sudo cp -a "$ENI" "$backup"
  msg "Commenting it out (backup: $backup)"
  sudo awk -v ifc="$PXE_IFACE" '
    $0 ~ "^[[:space:]]*(auto|allow-hotplug|iface)[[:space:]]+" ifc "([[:space:]]|$)" {
      print "# [disabled by aiken-fog-onebox] " $0; skip = 1; next
    }
    skip && /^[[:space:]]/ && NF { print "# " $0; next }
    { skip = 0; print }
  ' "$backup" | sudo tee "$ENI" >/dev/null
fi

# --- the bridge ---------------------------------------------------------------
if nmcli -t -f NAME con show | grep -qx "$BRIDGE"; then
  warn "Bridge connection '$BRIDGE' already exists — skipping creation."
else
  msg "Creating bridge $BRIDGE ($AWB_HOST_IP/$PREFIX) with $PXE_IFACE enslaved"
  sudo nmcli con add type bridge con-name "$BRIDGE" ifname "$BRIDGE" \
       ipv4.method manual ipv4.addresses "$AWB_HOST_IP/$PREFIX" \
       ipv4.never-default yes ipv6.method disabled bridge.stp no
  sudo nmcli con add type ethernet con-name "$BRIDGE-$PXE_IFACE" ifname "$PXE_IFACE" master "$BRIDGE"

  # DELETE any standalone profile for the NIC, do not merely disable it.
  # `autoconnect no` is not protection: the profile still activates on an
  # explicit `up`, and it keeps its address while it exists.
  while read -r uuid; do
    [ -n "$uuid" ] || continue
    msg "  removing standalone profile $uuid on $PXE_IFACE"
    sudo nmcli con delete "$uuid" >/dev/null 2>&1 || true
  done < <(nmcli -t -f UUID,DEVICE,NAME con show 2>/dev/null \
             | awk -F: -v ifc="$PXE_IFACE" -v br="$BRIDGE-$PXE_IFACE" \
                 '$3 != br && $2 == ifc {print $1}')

  sudo nmcli con up "$BRIDGE"
  sudo nmcli con up "$BRIDGE-$PXE_IFACE"
fi

# --- verify, rather than assume ------------------------------------------------
# These three together are what a working bridge looks like. Checking them here
# means a misconfiguration surfaces now instead of at the next reboot.
fail=0
addr="$(ip -br addr show "$PXE_IFACE" 2>/dev/null | awk '{print $3}')"
[ -z "$addr" ] || { warn "$PXE_IFACE still holds an address ($addr) — it must have none"; fail=1; }
[ -e "/sys/class/net/$BRIDGE/brif/$PXE_IFACE" ] \
  || { warn "$PXE_IFACE is not a member of $BRIDGE"; fail=1; }
routes="$(ip route | grep -c "dev $PXE_IFACE\|dev $BRIDGE" || true)"
[ "$routes" -le 1 ] || { warn "more than one route for the PXE segment — duplicate address"; fail=1; }
[ "$fail" -eq 0 ] && msg "Bridge verified: $PXE_IFACE addressless, enslaved, one route."

msg "Point your DHCP server at the bridge. For isc-dhcp-server:"
echo "    INTERFACESv4=\"$BRIDGE\"   in /etc/default/isc-dhcp-server, then restart it."
msg "If you intend to use FOG multicast, also disable bridge snooping (see README):"
echo "    sudo nmcli con mod $BRIDGE bridge.multicast-snooping no"
msg "Result:"; ip -br addr show "$BRIDGE" | sed 's/^/    /'
msg "Done. Next: ./30-provision-fog-vm.sh"
msg "RE-CHECK AFTER YOUR FIRST REBOOT — this step's failure mode only appears then."
