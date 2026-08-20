#!/usr/bin/env bash
# Wire up the unified boot menu on the AWB host:
#  - copy FOG's iPXE binaries into TFTP_ROOT/ipxe/
#  - write TFTP_ROOT/default.ipxe (the menu; MUST be this name — see docs)
#  - print the dhcpd class to paste into your AWB dhcpd.conf
. "$(dirname "$0")/lib.sh"; load_config

msg "Pulling FOG's iPXE binaries from the guest into $TFTP_ROOT/ipxe/"
sudo mkdir -p "$TFTP_ROOT/ipxe"
tmp="$(mktemp)"
ssh -o StrictHostKeyChecking=accept-new "debian@$FOG_VM_IP" \
    'sudo tar -C /tftpboot -cf - undionly.kpxe ipxe.efi snponly.efi i386-efi/ipxe.efi' > "$tmp"
sudo tar -C "$TFTP_ROOT/ipxe" -xf "$tmp"
# expose the ia32 binary under the name the dhcpd template expects
[ -f "$TFTP_ROOT/ipxe/i386-efi/ipxe.efi" ] && sudo cp "$TFTP_ROOT/ipxe/i386-efi/ipxe.efi" "$TFTP_ROOT/ipxe/i386-ipxe.efi"
sudo chown -R root:root "$TFTP_ROOT/ipxe"; sudo chmod -R a+rX "$TFTP_ROOT/ipxe"
rm -f "$tmp"

msg "Writing $TFTP_ROOT/default.ipxe"
render "$TMPL/default.ipxe.tmpl" /tmp/default.ipxe.rendered \
  "AWB_HOST_IP=$AWB_HOST_IP" "FOG_VM_IP=$FOG_VM_IP" "HTTP_PORT=$HTTP_PORT" \
  "AWB_KERNEL=$AWB_KERNEL" "AWB_INITRD=$AWB_INITRD" "AWB_NFS_EXPORT=$AWB_NFS_EXPORT" \
  "AWB_CMDLINE_EXTRA=$AWB_CMDLINE_EXTRA"
sudo cp /tmp/default.ipxe.rendered "$TFTP_ROOT/default.ipxe"

msg "dhcpd class to paste into your AWB dhcpd.conf (replaces the existing pxeclients class):"
render "$TMPL/dhcpd-pxeclients.conf.tmpl" /tmp/pxeclients.rendered "AWB_HOST_IP=$AWB_HOST_IP"
sed 's/^/    /' /tmp/pxeclients.rendered
warn "Do NOT modify the AppleNBI/BSDP class. After editing: sudo dhcpd -t && restart the DHCP server."
msg "Next: ./60-enable-http-boot.sh, then ./90-verify.sh"
