#!/usr/bin/env bash
# Install the virtualisation + boot stack on the AWB host (Debian/Ubuntu).
# Everything here is distro-native — nothing is compiled.
. "$(dirname "$0")/lib.sh"; load_config

msg "Installing host packages (qemu-kvm, libvirt, virtinst, lighttpd, genisoimage)"
sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
     qemu-kvm libvirt-daemon-system libvirt-clients virtinst \
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
msg "Done. Next: ./20-create-bridge.sh"
