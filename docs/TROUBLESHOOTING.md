# Troubleshooting & gotchas

The failure modes below are the ones that actually cost time. Read them before
you start; each is a real trap, not a hypothetical.

## iPXE loads, then "Chainloading failed" fetching `default.ipxe`

**Symptom.** Firmware downloads `ipxe/ipxe.efi` fine, iPXE starts, re-does DHCP,
then requests `tftp://<AWB_HOST_IP>/default.ipxe` and fails with
*"No such file or directory / Chainloading failed"*.

**Cause.** FOG builds its iPXE binaries with an **embedded script** ending:

```
chain tftp://${next-server}/default.ipxe || goto chainloadfailed
```

The binary **ignores the DHCP `filename` option on its second pass** and always
fetches a file literally named `default.ipxe` from `next-server`. So:

- The menu file **must** be named `default.ipxe` and live in your TFTP root.
- Do **not** try to steer the second pass with a DHCP `user-class = "iPXE"`
  rule — the binary never looks at it. That's a dead end (a real one; it looks
  like it should work and doesn't).

`scripts/50-setup-menu.sh` names the file correctly and keeps the `dhcpd` class
to a plain arch→binary map with no user-class logic. If you hand-roll it, do the
same.

## `default.ipxe` served, but the menu never appears / wrong binary

Check the DHCP **architecture** mapping. Firmware reports its type in DHCP option
93:

| option 93 | firmware | serve |
|---|---|---|
| `00:00` | legacy BIOS | `ipxe/undionly.kpxe` |
| `00:06` | 32-bit UEFI | `ipxe/i386-ipxe.efi` |
| `00:07`, `00:09` | 64-bit UEFI | `ipxe/ipxe.efi` |

Your `dhcpd.conf` needs `option arch code 93 = unsigned integer 16;` declared
(AWB configs usually already have it). Some UEFI NICs prefer `snponly.efi` over
`ipxe.efi` — it's staged alongside, so it's a one-line change, not a rebuild.

## No `/dev/kvm`, VM won't start

Hardware virtualisation is off in firmware. Enable **Intel VT-x** (or AMD-V) in
BIOS/UEFI and reboot. Verify:

```bash
grep -cE '\b(vmx|svm)\b' /proc/cpuinfo   # >0
ls /dev/kvm                              # exists
```

You do **not** need VT-d/IOMMU — that's only for PCI passthrough, which a
virtual-disk VM doesn't use. Don't add `intel_iommu=on` for this.

## AWB boots, but with a stale/old kernel after an AWB update

Because iPXE loads AWB's kernel directly, `default.ipxe`'s `:awb` entry is a
**hand-copy** of AWB's `grub.cfg` boot line. If AWB ships a new kernel, renames
`vmlinuz`/`initrd.img-*`, or changes its boot args, `default.ipxe` won't know and
will keep loading the old file/args.

**Fix:** after any AWB update, diff the two and re-sync:

```bash
grep -E 'linux|initrd' <TFTP_ROOT>/grub/grub.cfg
grep -E 'kernel|initrd' <TFTP_ROOT>/default.ipxe
```

## FOG installed, but PXE clients can't reach it

- The FOG VM's `svc` NIC must be on the **bridge** (`br-pxe`), not the NAT uplink.
  `virsh domiflist fog` should show one interface on the bridge.
- FOG must have installed with **`dodhcp=n`**. If a second DHCP server came up on
  the segment, PXE becomes a coin flip. Check nothing else answers DHCP:
  `sudo nmap --script broadcast-dhcp-discover` (from a client), or just confirm
  only the AWB `dhcpd` is running.

## Bridge step cut my SSH / took the segment down

Run `20-create-bridge.sh` from a shell on the **management** interface
(`UPLINK_IFACE`), never over `PXE_IFACE` — the script reconfigures `PXE_IFACE`.
Rollback:

```bash
sudo nmcli con down br-pxe
sudo nmcli con mod <PXE_IFACE> connection.autoconnect yes
sudo nmcli con up <PXE_IFACE>
```

## HTTP boot returns 404 for the kernel

`lighttpd`'s `server.document-root` must be your **TFTP root** (so
`http://host:8080/boot/vmlinuz` maps to `<TFTP_ROOT>/boot/vmlinuz`). If AWB
already runs a web server on `:80`, keep FOG's boot server on a different port
(`HTTP_PORT`, default 8080) and make sure `default.ipxe` uses that port.

## Two DHCP servers — don't

The single most common way to break PXE on a shared segment is a second DHCP
server. FOG's installer offers to be one; always answer no (`dodhcp=n`). Let the
AWB host's `dhcpd` be the only one, serving both the BSDP (Mac) and PXE (PC)
classes.
