#!/usr/bin/env bash
# Install FOG inside the guest, unattended, with dodhcp=n (no second DHCP server).
# Runs over SSH to the guest; the guest reaches the internet via its NAT uplink.
. "$(dirname "$0")/lib.sh"; load_config
SSH="ssh -o StrictHostKeyChecking=accept-new debian@$FOG_VM_IP"

msg "Rendering .fogsettings"
render "$TMPL/fogsettings.tmpl" /tmp/fogsettings.rendered \
  "FOG_VM_IP=$FOG_VM_IP" "FOG_SVC_IFACE=svc" "PXE_NETMASK=$PXE_NETMASK" "AWB_HOST_IP=$AWB_HOST_IP"

msg "Copying answers + cloning FOG $FOG_BRANCH in the guest"
$SSH 'sudo mkdir -p /opt/fog'
scp -o StrictHostKeyChecking=accept-new /tmp/fogsettings.rendered "debian@$FOG_VM_IP:/tmp/.fogsettings"
$SSH 'sudo mv /tmp/.fogsettings /opt/fog/.fogsettings'
$SSH "sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq && sudo apt-get install -y -qq git"
$SSH "[ -d ~/fogproject ] || git clone -q --depth 1 -b '$FOG_BRANCH' https://github.com/FOGProject/fogproject.git"

msg "Running installfog.sh -y (several minutes; installs apache/php/mysql/tftp/nfs IN THE GUEST)"
$SSH 'sudo systemd-run --unit=foginstall --collect bash -c "cd ~/fogproject/bin && ./installfog.sh -y > /var/log/foginstall.log 2>&1"'
# shellcheck disable=SC2016  # runs on the remote host; expansion is intended there
$SSH 'for _ in $(seq 1 90); do [ "$(systemctl is-active foginstall)" != active ] && break; sleep 8; done; systemctl show foginstall -p Result'
$SSH 'sudo tail -n 6 /var/log/foginstall.log'
msg "FOG web UI: http://$FOG_VM_IP/fog/management  (default login fog/password — CHANGE IT)"
msg "Next: ./50-setup-menu.sh"
