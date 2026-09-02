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

# A branch or tag name is a moving/ambiguous target; a commit id is not. Set
# FOG_COMMIT in config.env to assert exactly which tree you installed.
if [ -n "${FOG_COMMIT:-}" ]; then
  msg "Verifying the cloned commit matches the pinned release"
  got="$($SSH 'cd ~/fogproject && git rev-parse HEAD')"
  [ "$got" = "$FOG_COMMIT" ] \
    || die "FOG commit mismatch
  expected: $FOG_COMMIT
  actual:   $got"
  msg "  commit OK: $got"
else
  warn "FOG_COMMIT is not set — the cloned release is NOT verified. See config.example.env."
fi

msg "Running installfog.sh -y (several minutes; installs apache/php/mysql/tftp/nfs IN THE GUEST)"

# Resolve the clone path on the GUEST, as the login user.
# Do NOT use ~ inside the systemd-run command below: systemd-run executes as
# root, so ~ expands to /root — not the user home the clone lives in. The cd
# then fails, && short-circuits, and the install silently never runs while
# still reporting success.
# shellcheck disable=SC2016  # $HOME must expand on the GUEST, not here
FOGDIR="$($SSH 'echo $HOME/fogproject')"
msg "  clone at $FOGDIR on the guest"

# Do NOT pass --collect: it garbage-collects the unit the moment it exits, and
# `systemctl show` against a unit that no longer exists returns the defaults
# Result=success / ExecMainStatus=0 — so the check below would pass no matter
# what actually happened.
$SSH "sudo systemd-run --unit=foginstall bash -c 'cd $FOGDIR/bin && ./installfog.sh -y > /var/log/foginstall.log 2>&1'"

# shellcheck disable=SC2016  # runs on the remote host; expansion is intended there
$SSH 'for _ in $(seq 1 150); do [ "$(systemctl is-active foginstall)" != active ] && break; sleep 8; done'

res="$($SSH 'systemctl show foginstall -p Result --value')"
code="$($SSH 'systemctl show foginstall -p ExecMainStatus --value')"
msg "  unit result=$res exit=$code"
$SSH 'sudo tail -n 15 /var/log/foginstall.log' || true
$SSH 'sudo systemctl reset-failed foginstall' >/dev/null 2>&1 || true
[ "$code" = "0" ] || die "installfog.sh FAILED (exit $code) — see /var/log/foginstall.log in the guest"

msg "FOG web UI: http://$FOG_VM_IP/fog/management  (default login fog/password — CHANGE IT)"
msg "Next: ./50-setup-menu.sh"
