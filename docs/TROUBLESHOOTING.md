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

## FOG VM is `shut off` — was it suspended, or destroyed?

Two different failures look identical in `virsh list`, and only one is harmless.

```bash
sudo virsh dominfo "$FOG_VM_NAME" | grep -iE 'state|managed save'
```

| Output | Meaning |
|---|---|
| `State: shut off` + **`Managed save: yes`** | Suspended safely. Memory is on disk and will be restored. |
| `State: shut off` + **`Managed save: no`** | Genuinely destroyed. Any in-flight imaging is gone. |

**`virsh domstate` alone cannot tell these apart** — it prints `shut off` for
both. Always check the `Managed save` field.

### Why a guest gets shut down behind your back

The usual culprit is **`libvirt-guests`**, not systemd killing qemu.
`libvirt-daemon-system` ships `libvirtd.service` with `KillMode=process`, so
qemu is never reaped as a child of the daemon — restarting `libvirtd` leaves
guests running and simply re-attaches to them.

`libvirt-guests` is the service that acts on guests, and its built-in default
is `ON_SHUTDOWN=shutdown`. Whenever it stops — host reboot, package upgrade,
or an admin stopping it by hand — it shuts every running guest down. If
`/etc/default/libvirt-guests` only sets timeouts (the stock file does), that
default applies silently.

`10-install-host-deps.sh` now sets:

```sh
ON_SHUTDOWN=suspend      # managedsave to disk and restore, instead of destroying
ON_BOOT=start            # resume whatever was suspended
```

On an existing install, set those by hand and `systemctl enable libvirt-guests`.

### Testing this — restarting libvirtd proves nothing

```bash
sudo systemctl restart libvirtd          # does NOT exercise the failure path
```

A restart never stops `libvirt-guests`, so the VM keeps running and libvirtd
re-attaches. That looks like a pass and tells you nothing. Test the real path:

```bash
sudo systemctl stop  libvirt-guests
sudo virsh dominfo "$FOG_VM_NAME" | grep -i 'managed save'   # expect: yes
sudo systemctl start libvirt-guests
sudo virsh domstate  "$FOG_VM_NAME"                          # expect: running
```

## FOG VM does not come back after a host reboot

Separate cause from the above, and it bites even with `ON_SHUTDOWN=suspend`
set — the domain was created without autostart:

```bash
sudo virsh dominfo "$FOG_VM_NAME" | grep -i autostart    # 'disable' = it will not return
sudo virsh autostart "$FOG_VM_NAME"                      # writes /etc/libvirt/qemu/autostart/
systemctl is-enabled libvirtd                            # must be 'enabled' for the chain to hold
```

`30-provision-fog-vm.sh` now does this at build time. Older installs need it
applied by hand once.

> `virsh list --all` showing **no domains at all** is usually not a lost VM —
> an unprivileged user without membership in the `libvirt` group reads the
> session URI rather than the system one. Use `sudo virsh`, or add the user to
> the group.

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

## Everything worked, then the first reboot broke PXE entirely

**The single most expensive trap in this whole setup.** It is latent: the build
verifies green, clients boot, and then a reboot days later takes it all down.

**Symptom.** No client gets an address. `PXE_IFACE` has the bridge's IP on it,
the bridge no longer lists it as a member, and there are two routes for the
segment — the one on `PXE_IFACE` with no metric, so it wins:

```
10.10.0.0/24 dev eth1                            <- wins
10.10.0.0/24 dev br-pxe  ... metric 425
```

`/var/log/syslog` shows dhcpd refusing to start:

```
dhcpd: Multiple interfaces match the same subnet: eth1 br-pxe
dhcpd: Not configured to listen on any interfaces!
dhcpd: exiting.
```

**Cause.** NetworkManager on Debian/Ubuntu commonly runs with
`plugins=ifupdown,keyfile` and `managed=true`. Any stanza in
`/etc/network/interfaces` is therefore **regenerated as an NM connection profile
on every boot and activated**, pulling the NIC out of the bridge.

**Deleting the NM profile does not fix it.** It comes back after the next reboot
with a *new UUID* — which is the tell. Nor does `autoconnect no`: the profile
still activates on an explicit `up`, and it holds its address the whole time it
exists. The file is the source.

**Fix.** `20-create-bridge.sh` now comments the stanza out automatically (with a
timestamped backup) before creating the bridge. If you built the bridge by hand,
do it yourself:

```bash
sudo cp -a /etc/network/interfaces /etc/network/interfaces.bak.$(date +%s)
# comment out the stanza for PXE_IFACE; leave 'auto lo' alone
sudo nmcli con delete <the-generated-uuid>
sudo nmcli con up <BRIDGE>-<PXE_IFACE>
```

**Then reboot and check all three.** Nothing short of a reboot proves it:

```bash
ip -br addr show <PXE_IFACE>          # MUST be empty
ls /sys/class/net/<BRIDGE>/brif/      # MUST list <PXE_IFACE>
ip route | grep <your PXE subnet>     # MUST be exactly one line
```

## Four things that will lie to you

Worth knowing before you trust any of them while debugging:

| Check | The lie | Use instead |
|---|---|---|
| `systemctl is-active isc-dhcp-server` | Reports **active** while dhcpd has already exited. The unit looks healthy and serves nothing. | `ss -lnup \| grep :67`, and the `Listening on LPF/...` line in syslog |
| `tftpd-hpa` logs | Without `--verbose` it logs **only errors**, so a successful transfer is completely silent. Absence of log lines looks exactly like failure. | Add `--verbose` to `TFTP_OPTIONS` while commissioning |
| `systemctl show <unit> -p Result` after `systemd-run --collect` | `--collect` deletes the unit the moment it exits, and querying a unit that no longer exists returns `Result=success` / `ExecMainStatus=0`. The check can never fail. | Don't use `--collect` on anything whose exit status you intend to read |
| `zpool list` with a mismatched ZFS userland/kmod | Reported `ALLOC 0` on a pool holding 963 GB. | `zfs list` |

Also: `tftp: client does not accept options` in the log is usually **benign** —
UEFI firmware declining the tsize/blksize offer. It is not evidence of the
failure you are chasing.

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
