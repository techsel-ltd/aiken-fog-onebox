#!/usr/bin/env bash
# Install the virtualisation + boot stack on the AWB host (Debian/Ubuntu).
# Everything here is distro-native — nothing is compiled.
. "$(dirname "$0")/lib.sh"; load_config

msg "Installing host packages (qemu-kvm, libvirt, virtinst, lighttpd, genisoimage)"
# --no-install-recommends keeps this lean (69 packages -> 39 on Ubuntu 20.04).
# The three extras below are then REQUIRED explicitly, because they are only
# Recommends and dropping them breaks things quietly:
#   qemu-utils    - provides qemu-img, used to resize the cloud image (step 30)
#   dnsmasq-base  - libvirt's default NAT network needs it; without it the guest
#                   has no uplink and installfog.sh cannot fetch anything
#   iptables      - libvirt's NAT forwarding rules
sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
     qemu-kvm qemu-utils libvirt-daemon-system libvirt-clients virtinst \
     dnsmasq-base iptables \
     lighttpd genisoimage

msg "Checking hardware virtualisation (VT-x/AMD-V)"
if [ ! -e /dev/kvm ] || ! grep -qE '\b(vmx|svm)\b' /proc/cpuinfo; then
  warn "/dev/kvm missing or no vmx/svm flag."
  warn "Enable Intel VT-x (or AMD-V) in the BIOS/UEFI and reboot, then re-run."
  warn "VT-d/IOMMU is NOT needed — only required for PCI passthrough."
  die  "Aborting: KVM not available."
fi
msg "KVM OK. libvirt default NAT network:"
sudo virsh net-list --all | sed 's/^/    /'

msg "Configuring libvirt-guests to SUSPEND guests, not shut them down"
# libvirt-guests defaults to ON_SHUTDOWN=shutdown, so whenever that service
# stops it shuts every running guest down. A host reboot, a package upgrade
# that restarts the virtualisation stack, or an admin stopping the service by
# hand will therefore take FOG offline in the middle of imaging a machine.
# Suspend writes the guest's memory to disk (managedsave) and restores it.
LG=/etc/default/libvirt-guests
if [ -f "$LG" ]; then
  [ -f "$LG.onebox.bak" ] || sudo cp -a "$LG" "$LG.onebox.bak"
  # set_kv FILE KEY VALUE — replace the setting whether it is set or commented
  # out, else append it. Keeps re-runs idempotent.
  set_kv() {
    local f="$1" k="$2" v="$3"
    if sudo grep -qE "^[#[:space:]]*${k}=" "$f"; then
      sudo sed -i -E "s|^[#[:space:]]*${k}=.*|${k}=${v}|" "$f"
    else
      printf '%s=%s\n' "$k" "$v" | sudo tee -a "$f" >/dev/null
    fi
  }
  set_kv "$LG" ON_SHUTDOWN suspend
  set_kv "$LG" ON_BOOT     start
  sudo systemctl enable libvirt-guests >/dev/null 2>&1 || \
    warn "could not enable libvirt-guests — guests will not be restored on boot"
else
  warn "$LG not found — skipping. Guests may be shut down when libvirt-guests stops."
fi

msg "Done. Next: ./20-create-bridge.sh"
