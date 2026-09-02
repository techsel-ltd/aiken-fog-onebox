#!/usr/bin/env bash
# Create the FOG guest: Debian 12 cloud image + cloud-init, two NICs.
#   svc    -> the PXE bridge, static FOG_VM_IP (imaging interface)
#   uplink -> libvirt NAT,   DHCP (throwaway path so the guest can fetch packages)
# Optionally a second disk (FOG_IMAGES_ZVOL) for FOG's /images.
. "$(dirname "$0")/lib.sh"; load_config
need virt-install; need qemu-img; need genisoimage; need wget

IMAGES=/var/lib/libvirt/images
DISK="$IMAGES/${FOG_VM_NAME}.qcow2"
SEED="$IMAGES/${FOG_VM_NAME}-seed.iso"

# MACs are randomised unless pinned. Pinning is worth it: encode the guest's
# address in the last three bytes and `virsh domiflist` reads the IP back
# without logging into the guest.
rand_mac() { printf '52:54:00:%02x:%02x:%02x' $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)); }
SVC_MAC="${FOG_SVC_MAC:-$(rand_mac)}"
UPLINK_MAC="${FOG_UPLINK_MAC:-$(rand_mac)}"

PREFIX="$(prefix_from_netmask "$PXE_NETMASK")"
PUBKEY="$(cat "${GUEST_SSH_PUBKEY/#\~/$HOME}")"

# Optional dedicated volume for FOG's /images (LVM LV, ZFS zvol, whole disk...).
# Leave FOG_IMAGES_ZVOL unset to keep everything on the single root disk.
#
# Why a block device rather than an NFS mount from the host: FOG must itself
# NFS-export /images to the imaging clients. If the guest reached its store over
# NFS, FOG would be re-exporting an NFS mount - which the kernel supports only
# with fsid= on every export, refuses file locks and delegations outright, and
# which the linux-nfs wiki warns against rebooting. A block device lets FOG
# export a genuinely local filesystem.
images_disk=()
if [ -n "${FOG_IMAGES_ZVOL:-}" ]; then
  [ -b "$FOG_IMAGES_ZVOL" ] || die "FOG_IMAGES_ZVOL=$FOG_IMAGES_ZVOL is not a block device"
  images_disk=(--disk "path=$FOG_IMAGES_ZVOL,format=raw,bus=virtio")
  msg "Images volume: $FOG_IMAGES_ZVOL -> guest vdb (format and mount it at /images before step 40)"
fi

# --- download, VERIFY, then resize -------------------------------------------
# The checksum MUST be verified before qemu-img resize: resize rewrites the
# file, so a hash check afterwards compares against something already modified.
: "${DEBIAN_IMAGE_SHA512:?set DEBIAN_IMAGE_SHA512 in config.env - see config.example.env}"
STAGE="$(mktemp -d)"; trap 'rm -rf "$STAGE"' EXIT

msg "Downloading Debian cloud image"
wget -q --show-progress -O "$STAGE/img.qcow2" "$DEBIAN_IMAGE_URL"

msg "Verifying SHA512 before any modification"
actual="$(sha512sum "$STAGE/img.qcow2" | awk '{print $1}')"
if [ "$actual" != "$DEBIAN_IMAGE_SHA512" ]; then
  die "SHA512 MISMATCH
  expected: $DEBIAN_IMAGE_SHA512
  actual:   $actual"
fi
msg "  checksum OK"

sudo mv "$STAGE/img.qcow2" "$DISK"
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
     "${images_disk[@]}" \
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
if [ -n "${FOG_IMAGES_ZVOL:-}" ]; then
  msg "Next: format + mount vdb at /images in the guest, then ./40-install-fog.sh"
  msg "  e.g. sudo mkfs.ext4 -m 0 -L fog-images /dev/vdb && sudo mkdir -p /images"
  msg "       echo \"UUID=\$(sudo blkid -s UUID -o value /dev/vdb) /images ext4 defaults,noatime 0 2\" | sudo tee -a /etc/fstab"
  msg "       sudo mount /images"
else
  msg "Next: ./40-install-fog.sh"
fi
