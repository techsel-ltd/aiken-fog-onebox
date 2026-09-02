# aiken-fog-onebox

Run **FOG** (PC imaging) alongside an existing **Aiken WorkBench / AWB** (Mac
imaging) server on **one network segment, from one PXE menu** — pick which to
boot at power-on, AWB by default with a 5-second timeout.

FOG runs in a **KVM virtual machine** on the AWB host. AWB stays on bare metal,
untouched. The scripts here automate the whole thing and are config-driven, so
you set your IPs and interface names once and run them in order.

> Placeholders throughout use the `10.10.0.0/24` documentation range and generic
> interface names. Nothing in this repo is site-specific — copy
> `config.example.env` to `config.env` and edit it for your environment.

---

## The idea in one picture

```
                        AWB host (Debian/Ubuntu, bare metal)
   ┌──────────────────────────────────────────────────────────────────┐
   │  AWB: dhcpd · TFTP (:69) · NFS · MySQL · awbhttpd            :80   │
   │  added: lighttpd :8080  (serves the AWB kernel/initrd over HTTP)   │
   │                                                                    │
   │   br-pxe  10.10.0.1 ──┬─────────────────── PXE_IFACE (to clients)  │
   │                       │                                            │
   │                 ┌─────┴──────┐   libvirt/KVM guest                 │
   │                 │  FOG VM    │   Debian 12                         │
   │                 │  10.10.0.2 │   Apache/PHP/MySQL/TFTP/NFS (its own)│
   │                 └────────────┘   uplink → libvirt NAT (for installs)│
   └──────────────────────────────────────────────────────────────────┘
                               │  PXE segment 10.10.0.0/24
        ┌──────────────────────┼───────────────────────┐
     BIOS PC                UEFI PC                    Mac
   (PXEClient →           (PXEClient →            (BSDP → AWB NetBoot,
    iPXE → menu)           iPXE → menu)            never sees the menu)
```

**Why this works — the key insight:** AWB serves Macs over Apple **BSDP** and PCs
over **PXE**; these are different DHCP vendor-classes and never collide. What
*does* collide when you put FOG on the same box bare-metal is the *supporting*
services — both want `:80`, `:3306`, `:69`, `:67`. Putting FOG in a VM gives it
its own IP and its own copies of all of those, so **nothing on the AWB host has
to change** except adding one DHCP class and an HTTP server for speed.

**Why a VM, not a container:** FOG's imaging engine needs a kernel NFS server,
which won't run in an unprivileged container. A VM is the least-friction path
that just works.

---

## Prerequisites

- An existing, working **AWB host** on Debian/Ubuntu with `isc-dhcp-server`,
  `tftpd-hpa` and NFS already serving your Macs — this repo adds FOG beside it.
- A **second NIC** on the AWB host facing the imaging segment (`PXE_IFACE`), plus
  the NIC that carries its default route (`UPLINK_IFACE`).
- **Hardware virtualisation enabled in BIOS/UEFI** (Intel VT-x or AMD-V). You do
  **not** need VT-d/IOMMU — that's only for PCI passthrough.
- Root/sudo on the AWB host, and an SSH keypair (its public key is injected into
  the FOG guest).

---

## Quick start

```bash
cp config.example.env config.env
$EDITOR config.env               # set interfaces, IPs, AWB paths

cd scripts
./10-install-host-deps.sh        # qemu-kvm, libvirt, virtinst, lighttpd (distro pkgs)
./20-create-bridge.sh            # bridge PXE_IFACE so the FOG VM shares the segment
./30-provision-fog-vm.sh         # Debian 12 cloud image (checksum-verified) + cloud-init
#   -> if FOG_IMAGES_ZVOL is set, format and mount the guest's vdb at /images now
./40-install-fog.sh              # FOG 1.5.x inside the VM, unattended, dodhcp=n
./50-setup-menu.sh               # stage iPXE binaries + default.ipxe; prints the dhcpd class
#   -> paste the printed class into your AWB dhcpd.conf, `dhcpd -t`, restart it
./60-enable-http-boot.sh         # serve the AWB kernel/initrd over HTTP (fast)
./90-verify.sh                   # headless checks; then PXE-boot a BIOS and a UEFI client
```

Only step 50 has a manual action: it prints a `dhcpd` class for you to paste into
your AWB `dhcpd.conf`, because that file is yours and every site's is a little
different. It replaces the existing `pxeclients` class and **leaves the Apple
BSDP class untouched**.

---

## What each step changes

| Step | On the host | Reversible by |
|---|---|---|
| 10 | installs packages, checks KVM | apt remove |
| 20 | creates `br-pxe`, enslaves `PXE_IFACE`, moves the host's PXE IP onto it | `nmcli con down br-pxe`; re-enable the old profile |
| 30 | creates the FOG VM (disk + seed ISO under `/var/lib/libvirt/images`); optionally attaches `FOG_IMAGES_ZVOL` as `vdb` | `virsh destroy fog; virsh undefine fog` |
| 40 | nothing on the host — installs FOG **inside the guest** | delete the VM |
| 50 | writes `TFTP_ROOT/ipxe/*` and `TFTP_ROOT/default.ipxe`; you edit `dhcpd.conf` | restore your `dhcpd.conf` backup |
| 60 | points lighttpd at `TFTP_ROOT` on `:8080` | `systemctl stop lighttpd` |

---

## Boot flow, once it's live

1. Client PXE-boots → your `dhcpd` hands it the right **iPXE binary** for its
   firmware (BIOS/UEFI32/UEFI64).
2. iPXE loads and fetches **`default.ipxe`** — the menu.
3. No keypress for 5 s → **Aiken WorkBench** (iPXE loads AWB's kernel/initrd
   directly over **HTTP**). Pick **FOG** → chains to the FOG VM's `boot.php`.
4. Macs are never involved: they match the BSDP class and NetBoot AWB as before.

---

## Design decisions

| Decision | Why |
|---|---|
| FOG virtualised, AWB bare metal | Box the component you'd rather reinstall. FOG is a DB + `/images`; AWB is your production imaging server. |
| KVM VM, not a container | FOG needs a kernel NFS server — won't run unprivileged. |
| Debian 12 guest | First-class FOG target, no snap, no SELinux/firewalld friction. |
| One shared DHCP server (AWB's), `dodhcp=n` on FOG | Two DHCP servers on one L2 makes PXE a coin flip. |
| iPXE loads the AWB kernel directly (no grub) | One less layer, and enables HTTP boot. **Trade-off:** `default.ipxe`'s kernel line mirrors AWB's `grub.cfg` by hand — re-sync it if AWB's kernel changes. |
| Menu file named `default.ipxe`; no DHCP `user-class` logic | FOG's iPXE binaries hardcode `chain …/default.ipxe` and ignore the DHCP filename on their second pass. See [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md). |
| Kernel/initrd over HTTP (lighttpd :8080) | TFTP's lockstep transfer is the boot bottleneck; HTTP streams it ~10–15× faster. Port 8080 avoids AWB's `:80`. |
| Cloud image checksum verified **before** `qemu-img resize` | `resize` rewrites the file, so a hash checked afterwards proves nothing. `DEBIAN_IMAGE_SHA512` is required, and the URL is pinned to a dated directory because `latest/` moves under you. |
| `/images` on a block device (`FOG_IMAGES_ZVOL`), not an NFS mount from the host | FOG must itself NFS-export `/images` to the imaging clients. Fed by NFS, it would be **re-exporting an NFS mount** — which needs `fsid=` on every export, refuses file locks and delegations outright, and which the linux-nfs wiki warns not to reboot. A block device lets FOG export a genuinely local filesystem. |

---

## Multicast (UDPcast)

Deploying one image to many machines at once. The scripts don't configure this,
but the setup they produce is compatible with it, and there is one trap worth
knowing before you try.

FOG and the clients are already on the same L2 segment, which is the hard
requirement — udpcast does not cross a router without multicast routing. FOG's
settings then come from `.fogsettings` (`FOG_UDPCAST_INTERFACE` must be the
guest's imaging NIC, `svc` here); check them under **FOG Configuration → FOG
Settings**.

**The trap: IGMP snooping with no querier.** A snooping switch only forwards
multicast to ports it has learned have subscribers, and it learns that from IGMP
queries. On an isolated imaging segment nothing sends queries — so snooping
silently prunes the traffic and multicast "just hangs". **This applies twice**,
because a Linux bridge does its own snooping and will prune multicast to the FOG
guest's own tap.

On a dedicated imaging segment the simplest reliable answer is to turn snooping
off on both the bridge and the switch VLAN — the traffic is destined for every
client anyway:

```bash
nmcli con mod br-pxe bridge.multicast-snooping no   # persistent
```

The alternative is an IGMP querier on the segment. Note NetworkManager before
1.24 cannot set `bridge.multicast-querier`, so on older hosts that route needs a
systemd unit writing to `/sys/class/net/br-pxe/bridge/multicast_querier`.

> Not yet exercised end-to-end by this repo's testing — the settings and the
> snooping behaviour are documented, a real multi-machine deploy is not.

## Memory sizing, if you back `/images` with ZFS

Using `FOG_IMAGES_ZVOL` on a ZFS pool means the ARC now competes for host RAM.
Default `zfs_arc_max` is **half of RAM**, which is usually too much here.

```
ARC = total RAM − guest RAM − host reserve
```

**Size the host reserve properly, because ARC caches only ZFS.** The things a
PXE/imaging host reads most are frequently *not* on the pool:

- the **AWB diskless root** (`AWB_NFS_EXPORT`) that every client NFS-mounts
- the guest's own qcow2 under `/var/lib/libvirt/images`
- the TFTP root

Those live on the ordinary filesystem and are served by the **page cache**, which
ARC does not cover and actively competes with. Sizing ARC to "all the remaining
RAM" starves the diskless-boot path — the one thing every client touches.

A worked example on a 78 GiB host: 8 GiB guest, **12 GiB host reserve** (~2 GiB
processes + ~6 GiB page cache for the non-ZFS hot set + burst), 56 GiB ARC.

```bash
echo "options zfs zfs_arc_max=<bytes>" | sudo tee /etc/modprobe.d/zfs.conf
echo <bytes> | sudo tee /sys/module/zfs/parameters/zfs_arc_max   # live, no reboot
```

Leave `primarycache=all` on the zvol. Setting `primarycache=metadata` stops ARC
caching zvol data so the guest's page cache does it instead — the wrong trade
when ARC is the far larger cache. The guest does double-cache hot blocks, but
that duplication is small relative to ARC and not worth optimising away.

Tune on measurement once real imaging has happened, not on this arithmetic:

```bash
awk '/^size/{s=$3} /^c_max/{c=$3} /^hits/{h=$3} /^misses/{m=$3} \
  END{printf "ARC %.1f/%.1f GiB, hit %.1f%%\n", s/2^30, c/2^30, 100*h/(h+m)}' \
  /proc/spl/kstat/zfs/arcstats
```

## Not covered (yet)

- Production hardening (TLS, the FOG portal's default `fog`/`password` — change
  it), and DR/replication of your images.

See [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) for the failure modes worth
knowing before you start.

## Credits

Written by Damian K Labudek at Techsel Ltd, a computer refurbishment business in
Warrington, UK. See [AUTHORS](AUTHORS).

## License

MIT — see [LICENSE](LICENSE). Copyright (c) 2026 Techsel Ltd.
