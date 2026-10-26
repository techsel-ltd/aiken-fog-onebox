#!/usr/bin/env bash
# Serve TFTP_ROOT over HTTP (lighttpd on HTTP_PORT) so iPXE streams the AWB
# kernel/initrd instead of grinding through TFTP's lockstep transfer.
. "$(dirname "$0")/lib.sh"; load_config

msg "Configuring lighttpd: document-root=$TFTP_ROOT port=$HTTP_PORT${HTTP_EXTRA_CONF:+ + include $HTTP_EXTRA_CONF}"
# Render and test first: a bad HTTP_EXTRA_CONF or a broken include stops here, before the live file changes.
conf="$(mktemp)"; trap 'rm -f "$conf"' EXIT
render_http_conf "$conf"
sudo lighttpd -tt -f "$conf"
sudo cp -a /etc/lighttpd/lighttpd.conf "/etc/lighttpd/lighttpd.conf.bak.$(date +%s)" 2>/dev/null || true
sudo install -m 0644 "$conf" /etc/lighttpd/lighttpd.conf
sudo systemctl enable --now lighttpd
sudo systemctl restart lighttpd

msg "Verifying HTTP serves the kernel"
if command -v wget >/dev/null; then
  wget -q -S --spider "http://$AWB_HOST_IP:$HTTP_PORT/$AWB_KERNEL" 2>&1 | grep -E 'HTTP/|Content-Length' | sed 's/^/    /'
fi
msg "The menu (default.ipxe from step 50) already points at http://$AWB_HOST_IP:$HTTP_PORT/"
msg "Done. Run ./90-verify.sh, then PXE-boot a client."
