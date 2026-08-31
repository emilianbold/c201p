# Debian Trixie image for Asus C201P

Automated build of a ready-to-flash Debian 13 (Trixie) SD card image for the
Asus C201P Chromebook. Download, decompress, `dd` to a card, boot.

## What's included

| Component | Details |
|-----------|---------|
| OS | Debian Trixie (armhf) |
| Kernel | `linux-image-armmp` (Debian stock, 6.12+) |
| Desktop | MATE + LightDM |
| Browser | Firefox ESR |
| WiFi | Built-in BCM4354 (`firmware-brcm80211` + veyron NVRAM) |
| Boot | Depthcharge → U-Boot (signed KERN-A) → extlinux.conf → Linux + initrd |

## Download and flash

Grab the latest `.img.xz` from the [Releases](../../releases/latest) page,
decompress, and `dd` it to a card (≥ 8 GB). Each release also carries
`debian-c201p-uboot.kpart` — the signed U-Boot binary alone, for reflashing
just KERN-A without touching the rootfs.

> **Run `sgdisk -e /dev/sdX` after flashing.** The image is 7 GB; on a larger
> card the GPT backup header ends up in the wrong place, and Depthcharge
> refuses to boot on an inconsistent GPT.

Larger card? Grow the root partition after first boot:
`growpart /dev/mmcblk1 2 && resize2fs /dev/mmcblk1p2` (needs `cloud-guest-utils`).

## First boot

1. Make sure the Chromebook is in **developer mode** with external boot enabled.
   See *Preparing the Chromebook* below if you haven't done this.
2. Insert the SD card (or USB drive).
3. Power on. At the developer mode warning screen press **Ctrl+U**.
4. If nothing happens: remove the media, reinsert it, wait 5 seconds, then
   Ctrl+U again. Depthcharge timing quirk.
5. LightDM starts automatically. Log in as `user`.

## Default credentials

| Account | Password |
|---------|----------|
| `user` | `trixie` |
| `root` | `trixie` |

Change both on first boot: `passwd` (for the current user) and `sudo passwd root`.

## Preparing the Chromebook

Skip this section if you already have developer mode and USB boot enabled.

### Enter developer mode

> **Warning:** erases local ChromeOS data.

1. Power off.
2. Hold **Esc + Refresh**, press **Power**.
3. At the Recovery screen press **Ctrl+D** and confirm.
4. Wait 15–20 minutes.

### Enable USB/SD boot

Boot into ChromeOS, open crosh (`Ctrl+Alt+T`):

```
shell
sudo su
crossystem dev_boot_usb=1 dev_boot_signed_only=0
```

---

## Building the image yourself

### Prerequisites (Debian/Ubuntu x86_64 host)

```bash
sudo apt install debootstrap debian-archive-keyring qemu-user-static binfmt-support gdisk cgpt curl u-boot-tools vboot-utils gcc-arm-linux-gnueabihf bison flex libssl-dev python3-setuptools
```

### Run

```bash
sudo ./build.sh
```

Override defaults with environment variables:

```bash
sudo IMAGE_FILE=my.img IMAGE_SIZE=8G ./build.sh
```

The script takes 30–60 minutes depending on your network speed and CPU.

---

## Build notes / gotchas

**Why U-Boot instead of booting the kernel directly.** `KERN-A` is the
ChromeOS kernel partition — the signed payload Depthcharge boots. Putting the
Linux kernel there directly does work, and Depthcharge will carry an initrd in
the FIT, but the whole signed body has to fit its staging buffer (~16 MB in
practice) and Debian's initrd does not. Avoiding the initrd means building a
custom kernel with the storage drivers compiled in — and then every kernel
update means rebuilding and re-signing it by hand.

So `KERN-A` holds **U-Boot** instead (built from upstream source, `flags=7`
keyblock). Depthcharge runs U-Boot; U-Boot reads
`/boot/extlinux/extlinux.conf` from the ext4 root and boots Debian's stock
kernel and initrd as ordinary files, where no size limit applies. Kernel
upgrades are then just `apt upgrade`, with nothing to re-sign.

Two packaging details matter: U-Boot is built
`CONFIG_POSITION_INDEPENDENT=y` (Depthcharge loads the FIT at `0x02000000`, not
U-Boot's link base), and the FIT ships `u-boot-dtb.bin` (U-Boot with its control
DTB appended — a bare `u-boot.bin` finds no DTB and dies early).

Kernel updates are handled automatically by the postinst hook; just `apt
upgrade` and reboot.

---

## Known issues

- **Boot hang / white screen:** Remove and reinsert the media, wait 5 seconds,
  then Ctrl+U. A full power cycle (hold power 10 s) often helps.
- **Volume media keys (F8–F10):** May not work; keymap issue with the generic
  `armmp` kernel.
- **HDMI audio:** Not configured by default. Video output works.
- **Bluetooth:** `btsdio` is blacklisted to prevent suspend crashes, and the
  BCM4354 patchram firmware is not redistributable, so Bluetooth is unavailable.

---

## License

This project's own code (`build.sh`, `files/`, the U-Boot patches, docs, CI)
is [ISC](LICENSE). The signed U-Boot binary is GPL-2.0 (U-Boot's own
license) — every release ships `debian-c201p-uboot-LICENSE.txt` alongside it.
Debian and the packages it installs each carry their own license; there is
no single license for a Debian system, and this project doesn't impose one.

The veyron WiFi NVRAM file (see `build.sh`) is downloaded from
ArchLinuxARM, but originates from Google's own ChromiumOS `board-overlays`
repo, where the packaging ebuild declares it `LICENSE="BSD-Google"`. Since
Google may itself be redistributing Broadcom's `LICENCE.broadcom_bcm43xx`
terms under that classification, this project ships both license texts
alongside the file.
