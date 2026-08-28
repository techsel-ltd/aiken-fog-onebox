#!/usr/bin/env bash
# Create the FOG guest: Debian 12 cloud image + cloud-init, two NICs.
#   svc    -> the PXE bridge, static FOG_VM_IP (imaging interface)
#   uplink -> libvirt NAT,   DHCP (throwaway path so the guest can fetch packages)
. "$(dirname "$0")/lib.sh"; load_config
need virt-install; need qemu-img; need genisoimage; need wget

IMAGES=/var/lib/libvirt/images
DISK="$IMAGES/${FOG_VM_NAME}.qcow2"
SEED="$IMAGES/${FOG_VM_NAME}-seed.iso"
SVC_MAC="52:54:00:$(printf '%02x:%02x:%02x' $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)))"
UPLINK_MAC="52:54:00:$(printf '%02x:%02x:%02x' $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)))"
PREFIX="$(prefix_from_netmask "$PXE_NETMASK")"
PUBKEY="$(cat "${GUEST_SSH_PUBKEY/#\~/$HOME}")"

msg "Downloading Debian cloud image"
sudo wget -q --show-progress -O "$DISK" "$DEBIAN_IMAGE_URL"
sudo qemu-img resize "$DISK" "${FOG_VM_DISK_GB}G"

msg "Building cloud-init NoCloud seed"
WORK="$(mktemp -d)"
render "$TMPL/cloud-init-meta-data.tmpl"     "$WORK/meta-data"
render "$TMPL/cloud-init-user-data.tmpl"     "$WORK/user-data"     "SSH_PUBKEY=$PUBKEY"
render "$TMPL/cloud-init-network-config.tmpl" "$WORK/network-config" \
       "SVC_MAC=$SVC_MAC" "UPLINK_MAC=$UPLINK_MAC" "FOG_VM_IP=$FOG_VM_IP" "PXE_PREFIX=$PREFIX"
sudo genisoimage -quiet -output "$SEED" -volid cidata -joliet -rock \
     "$WORK/user-data" "$WORK/meta-data" "$WORK/network-config"
rm -rf "$WORK"

msg "Creating VM '$FOG_VM_NAME' (svc -> $BRIDGE @ $FOG_VM_IP, uplink -> $LIBVIRT_NAT_NET)"
sudo virt-install --name "$FOG_VM_NAME" --memory "$FOG_VM_RAM_MB" --vcpus "$FOG_VM_VCPUS" \
     --os-variant generic \
     --disk path="$DISK",format=qcow2,bus=virtio \
     --disk path="$SEED",device=cdrom \
     --network bridge="$BRIDGE",mac="$SVC_MAC",model=virtio \
     --network network="$LIBVIRT_NAT_NET",mac="$UPLINK_MAC",model=virtio \
     --import --graphics none --noautoconsole

msg "Enabling autostart so the guest returns after a host reboot"
# Without this the domain is created with "Autostart: disable" and simply does
# not come back when the host reboots — FOG is silently absent until someone
# notices imaging is down and starts it by hand.
sudo virsh autostart "$FOG_VM_NAME"

msg "Waiting for the guest to answer SSH on $FOG_VM_IP ..."
for _ in $(seq 1 40); do
  if bash -c "echo > /dev/tcp/$FOG_VM_IP/22" 2>/dev/null; then msg "guest is up"; break; fi
  sleep 3
done
msg "Done. Reach it with:  ssh debian@$FOG_VM_IP"
msg "Next: ./40-install-fog.sh"
