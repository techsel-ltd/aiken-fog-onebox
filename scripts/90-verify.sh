#!/usr/bin/env bash
# Headless checks. The only thing this can't do is drive a physical PXE client —
# boot a BIOS and a UEFI machine to fully confirm.
. "$(dirname "$0")/lib.sh"; load_config
ok(){ printf '    \033[1;32mOK\033[0m  %s\n' "$*"; }
no(){ printf '    \033[1;31mXX\033[0m  %s\n' "$*"; }

msg "dhcpd config valid?"; if sudo dhcpd -t >/dev/null 2>&1; then ok "dhcpd -t"; else no "dhcpd -t FAILED"; fi

msg "TFTP serves iPXE + menu from $AWB_HOST_IP"
python3 - "$AWB_HOST_IP" <<'PY'
import socket,struct,sys
ip=sys.argv[1]
def tget(fn):
    s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);s.settimeout(4)
    s.sendto(b"\x00\x01"+fn.encode()+b"\x00octet\x00",(ip,69))
    try:
        d,a=s.recvfrom(1024); return struct.unpack("!H",d[:2])[0]==3
    except socket.timeout: return False
for f in ["default.ipxe","ipxe/undionly.kpxe","ipxe/ipxe.efi"]:
    print(("    OK  tftp "+f) if tget(f) else ("    XX  tftp "+f+" MISSING"))
PY

msg "HTTP serves the AWB kernel/initrd"
for f in "$AWB_KERNEL" "$AWB_INITRD"; do
  code=$(wget -q -S --spider "http://$AWB_HOST_IP:$HTTP_PORT/$f" 2>&1 | awk '/HTTP\//{c=$2} END{print c}')
  if [ "$code" = 200 ]; then ok "http $f ($code)"; else no "http $f ($code)"; fi
done

msg "FOG reachable + iPXE endpoint"
if wget -qO- --timeout=6 "http://$FOG_VM_IP/fog/service/ipxe/boot.php" 2>/dev/null | head -1 | grep -q '#!ipxe'; then
  ok "FOG boot.php serves iPXE"; else no "FOG boot.php not serving"; fi
msg "If all green, PXE-boot a BIOS and a UEFI client to finish."
