#!/bin/bash
# SPDX-License-Identifier: ISC
# build.sh — Build a Debian Trixie SD card image for the Asus C201P Chromebook.
#
# Must be run as root on a Debian/Ubuntu x86_64 host.
# Usage: sudo ./build.sh
#
# Required host packages:
#   apt install debootstrap debian-archive-keyring qemu-user-static binfmt-support gdisk cgpt curl u-boot-tools vboot-utils gcc-arm-linux-gnueabihf bison flex libssl-dev python3-setuptools
#
# files/ mirrors the target filesystem — everything under it is installed into
# the image at the matching path (files/home/ goes to the user's home). Edit
# those files directly; they are not generated.
#
# Boot method: Depthcharge loads a signed KERN-A holding U-Boot (built from
# source, flags=7 keyblock, packaged as a position-independent FIT at
# 0x02000000). U-Boot reads /boot/extlinux/extlinux.conf from the ext4 root and
# boots Linux with its full initrd. This keeps Debian's stock kernel and needs
# no re-signing on kernel upgrade.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Configuration ──────────────────────────────────────────────────────────────
IMAGE_FILE="${IMAGE_FILE:-debian-c201p.img}"
# Standalone copy of the signed U-Boot kpart written to KERN-A in Step 6 --
# lets someone re-flash just U-Boot (e.g. `cgpt`/`dd` onto KERN-A) without
# rebuilding or re-flashing the whole disk image.
UBOOT_KPART_FILE="${IMAGE_FILE%.img}-uboot.kpart"
# The kpart above is a GPL-2.0 binary (U-Boot's own license)
UBOOT_LICENSE_FILE="${IMAGE_FILE%.img}-uboot-LICENSE.txt"
# The WiFi NVRAM file (see the "Per-board WiFi NVRAM" section below) is not
# our own code either -- ship the two license texts that may apply to it.
NVRAM_LICENSE_FILE="${IMAGE_FILE%.img}-wifi-nvram-LICENSE.txt"
# Sized for a full MATE desktop + firefox-esr. Rough budget: base ~0.9G,
# MATE (incl. -extras) ~2.8G, firefox ~0.3G, kernel+initrd ~0.2G, plus the
# 64M KERN-A partition — call it ~4.3G used, so 7G leaves
# real headroom. Running out mid-build wastes a ~30 min CI run, so err large:
# the image is mostly zeros and xz compresses it away before upload.
IMAGE_SIZE="${IMAGE_SIZE:-7168M}"
DEBIAN_SUITE="trixie"
DEBIAN_MIRROR="http://deb.debian.org/debian"
HOSTNAME="c201"
USERNAME="user"
PASSWORD="trixie"       # Change after first login: passwd user
ROOT_PASSWORD="trixie"  # Change after first login: passwd root

# Change to your timezone; see /usr/share/zoneinfo/ for all options.
# Examples: America/New_York, Europe/London, Asia/Tokyo, UTC
TIMEZONE="Etc/UTC"


# ── State ──────────────────────────────────────────────────────────────────────
MOUNT_DIR="$(mktemp -d /tmp/c201-build-XXXXXX)"
LOOP_DEV=""

# ── Helpers ────────────────────────────────────────────────────────────────────
log() { echo "▸ $*"; }

cleanup() {
    set +e
    log "Cleaning up..."
    # Remove helper files we planted
    rm -f "${MOUNT_DIR}/usr/bin/qemu-arm-static"
    # Unmount in reverse order
    for sub in dev/pts dev sys proc; do
        mountpoint -q "${MOUNT_DIR}/${sub}" 2>/dev/null && umount -l "${MOUNT_DIR}/${sub}"
    done
    mountpoint -q "$MOUNT_DIR" 2>/dev/null && umount -l "$MOUNT_DIR"
    [ -n "$LOOP_DEV" ] && losetup -d "$LOOP_DEV" 2>/dev/null
    rm -rf "$MOUNT_DIR"
}
trap cleanup EXIT

# ── Preflight ──────────────────────────────────────────────────────────────────
[ "$(id -u)" -eq 0 ] || { echo "Run as root (sudo ./build.sh)"; exit 1; }

missing=()
for cmd in debootstrap qemu-arm-static sgdisk cgpt losetup mkfs.ext4 curl \
           mkimage vbutil_kernel arm-linux-gnueabihf-gcc; do
    command -v "$cmd" &>/dev/null || missing+=("$cmd")
done
if [ "${#missing[@]}" -gt 0 ]; then
    echo "Missing tools: ${missing[*]}"
    echo "  apt install debootstrap debian-archive-keyring qemu-user-static binfmt-support gdisk cgpt curl u-boot-tools vboot-utils gcc-arm-linux-gnueabihf bison flex libssl-dev python3-setuptools"
    exit 1
fi

for k in root_key.vbprivk kernel_data_key.vbpubk kernel_data_key.vbprivk; do
    [ -f "/usr/share/vboot/devkeys/${k}" ] && continue
    echo "ChromeOS dev key /usr/share/vboot/devkeys/${k} not found — needed to sign the U-Boot kpart."
    echo "  apt install vboot-utils"
    exit 1
done

if [ ! -f /usr/share/keyrings/debian-archive-keyring.gpg ]; then
    echo "Debian archive keyring not found — debootstrap cannot verify Release signatures."
    echo "  apt install debian-archive-keyring"
    exit 1
fi

# ── Step 0: Build and sign U-Boot as the KERN-A payload ───────────────────────
# Depthcharge loads the signed KERN-A and runs it; KERN-A holds U-Boot (not the
# Linux kernel). U-Boot then reads /boot/extlinux/extlinux.conf from the ext4
# root, loads vmlinuz + initrd + DTB, and boots Linux. Do this before the long
# debootstrap so a build failure surfaces early.
log "[0/7] Building and signing U-Boot..."
UBOOT_DIR="${SCRIPT_DIR}/u-boot"

# u-boot/ is a git submodule pinned to the exact upstream v2024.04 tag -- no
# vendored copy, no drift to audit. What this board needs beyond stock U-Boot
# is one small, independently-verified patch (VEYRON_CHAINLOAD: skip
# re-initialising PMIC/PLL/regulators Depthcharge already configured, when
# U-Boot is chainloaded rather than started from SPL).
#
# Reset the submodule to its pinned commit first: build.sh may be run more
# than once against the same checkout, and both the patch and the subsequent
# `make` leave the submodule's working tree modified. Re-applying the patch
# onto an already-patched tree would fail the second time around.
git -C "$UBOOT_DIR" checkout -q -- .
git -C "$UBOOT_DIR" clean -qfdx
# Apply from inside the submodule's own git context (git -C), not
# --directory= from the superproject: u-boot/ is a gitlink in the
# superproject's index, and git apply --directory= from outside it can
# refuse to write across that submodule boundary ("invalid path") -- this
# didn't reproduce in ad-hoc local testing but was confirmed in CI.
git -C "$UBOOT_DIR" apply "${SCRIPT_DIR}/patches/uboot/0001-board-critical.patch"
cp "${SCRIPT_DIR}/patches/uboot/chromebook_speedy_defconfig" \
    "$UBOOT_DIR/configs/chromebook_speedy_defconfig"

make -C "$UBOOT_DIR" ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- \
    chromebook_speedy_defconfig

# Stamp the commit into U-Boot's version string, so a running U-Boot can be
# traced back to a build. U-Boot's own scripts/setlocalversion would do this
# via CONFIG_LOCALVERSION_AUTO, but it bails unless it is run from the git root
# ("git rev-parse --show-cdup" must be empty) and u-boot/ is a subdirectory
# here, so it contributes nothing. Set CONFIG_LOCALVERSION by hand instead.
UBOOT_COMMIT="$(git -C "$SCRIPT_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"
sed -i "s|^CONFIG_LOCALVERSION=.*|CONFIG_LOCALVERSION=\"-g${UBOOT_COMMIT}\"|" \
    "$UBOOT_DIR/.config"
make -C "$UBOOT_DIR" ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- olddefconfig

log "    U-Boot config diagnostics:"
grep -E "POSITION_INDEPENDENT|BOOTCOMMAND|BOOTMETH_EXTLINUX|CMD_MMC|CMD_MEMORY|CONFIG_VIDEO|LOCALVERSION" \
    "$UBOOT_DIR/.config" | sed 's/^/      /' || true
make -C "$UBOOT_DIR" ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- -j"$(nproc)" 2>&1 | tail -5
log "    U-Boot build stamp: \
$(cat "$UBOOT_DIR/include/generated/version_autogenerated.h" 2>/dev/null \
  | sed -n 's/^#define PLAIN_VERSION "\(.*\)"$/\1/p') \
built $(date -u '+%Y-%m-%dT%H:%M:%SZ')"

# u-boot-dtb.bin = U-Boot with its control DTB appended (OF_SEPARATE needs it;
# a bare u-boot.bin finds no DTB and dies early).
UBOOT_BIN="$UBOOT_DIR/u-boot-dtb.bin"
[ -f "$UBOOT_BIN" ] || { echo "ERROR: ${UBOOT_BIN} missing — u-boot.bin alone has no control DTB and will not boot" >&2; exit 1; }
log "    U-Boot binary: $(basename "$UBOOT_BIN") ($(du -sh "$UBOOT_BIN" | cut -f1))"

# FIT: package U-Boot the way our Debian kernel booted — type=kernel, loaded and
# entered at 0x02000000. POSITION_INDEPENDENT=y lets it run there.
ITS=$(mktemp /tmp/uboot-XXXXXX.its)
cat > "$ITS" <<FITS
/dts-v1/;
/ {
    description = "U-Boot chainload for veyron-speedy";
    #address-cells = <1>;
    images {
        kernel {
            description = "U-Boot";
            type = "kernel";
            arch = "arm";
            os = "linux";
            data = /incbin/("${UBOOT_BIN}");
            compression = "none";
            load = <0x02000000>;
            entry = <0x02000000>;
            hash-1 { algo = "sha256"; };
        };
        fdt-1 {
            description = "u-boot control dtb";
            data = /incbin/("${UBOOT_DIR}/u-boot.dtb");
            type = "flat_dt";
            arch = "arm";
            compression = "none";
            hash-1 { algo = "sha256"; };
        };
    };
    configurations {
        default = "config-1";
        config-1 { description = "U-Boot"; kernel = "kernel"; fdt = "fdt-1"; };
    };
};
FITS
ITB=$(mktemp /tmp/uboot-XXXXXX.itb)
mkimage -f "$ITS" "$ITB" >/dev/null

# flags=7 keyblock — veyron Depthcharge rejects the standard 0x17.
KEYBLOCK=$(mktemp /tmp/kernel-XXXXXX.keyblock)
vbutil_keyblock --pack "$KEYBLOCK" --flags 7 \
    --signprivate /usr/share/vboot/devkeys/root_key.vbprivk \
    --datapubkey /usr/share/vboot/devkeys/kernel_data_key.vbpubk
BOOTLOADER=$(mktemp /tmp/bootloader-XXXXXX.bin)
dd if=/dev/zero of="$BOOTLOADER" bs=512 count=1 2>/dev/null
UBOOT_CONFIG=$(mktemp /tmp/config-XXXXXX)
printf '\n' > "$UBOOT_CONFIG"
UBOOT_KPART=$(mktemp /tmp/uboot-XXXXXX.kpart)
vbutil_kernel --pack "$UBOOT_KPART" --version 1 --arch arm \
    --vmlinuz "$ITB" --keyblock "$KEYBLOCK" \
    --signprivate /usr/share/vboot/devkeys/kernel_data_key.vbprivk \
    --config "$UBOOT_CONFIG" --bootloader "$BOOTLOADER"
rm -f "$ITS" "$ITB" "$KEYBLOCK" "$BOOTLOADER" "$UBOOT_CONFIG"
log "    U-Boot kpart ready: $(du -sh "$UBOOT_KPART" | cut -f1)"

# ── Step 1: Create image ───────────────────────────────────────────────────────
log "[1/7] Creating ${IMAGE_SIZE} image: ${IMAGE_FILE}"
fallocate -l "$IMAGE_SIZE" "$IMAGE_FILE" 2>/dev/null \
    || truncate -s "$IMAGE_SIZE" "$IMAGE_FILE"

# ── Step 2: Partition ──────────────────────────────────────────────────────────
log "[2/7] Partitioning..."
# sgdisk creates the GPT and partitions; cgpt sets the ChromeOS-specific boot
# flags that sgdisk doesn't know about. cgpt create on a plain file doesn't
# produce a GPT that the Linux loop device driver will parse, so sgdisk is
# needed for the initial table.
# KERN-A holds the signed U-Boot kpart (~1-2 MB). 64 MB is far more than enough;
# the kernel + initrd live on the ext4 ROOTFS and are loaded by U-Boot, so
# there's no Depthcharge staging-buffer limit to worry about here.
sgdisk -o -a 8192 \
    -n 1:8192:+64M -t 1:7F00 -c 1:"KERN-A" \
    -n 2:0:0       -t 2:8300 -c 2:"ROOTFS" \
    "$IMAGE_FILE"
cgpt add -i 1 -S 1 -T 5 -P 10 "$IMAGE_FILE"

LOOP_DEV=$(losetup --partscan --find --show "$IMAGE_FILE")
PART1="${LOOP_DEV}p1"
PART2="${LOOP_DEV}p2"

# Give the kernel a moment to expose partition devices
for i in 1 2 3; do
    [ -b "$PART2" ] && break
    sleep "$i"
done
[ -b "$PART2" ] || { echo "Partition device ${PART2} not found"; exit 1; }

log "[2/7] Formatting root partition..."
mkfs.ext4 -F -L root "$PART2"

# ── Step 3: First-stage debootstrap ───────────────────────────────────────────
log "[3/7] Debootstrap first stage..."
mount "$PART2" "$MOUNT_DIR"
debootstrap --arch=armhf --foreign "$DEBIAN_SUITE" "$MOUNT_DIR" "$DEBIAN_MIRROR"

# Enable ARM execution via binfmt_misc
cp /usr/bin/qemu-arm-static "${MOUNT_DIR}/usr/bin/"
update-binfmts --enable qemu-arm 2>/dev/null || true

# ── Step 4: Second-stage debootstrap ──────────────────────────────────────────
log "[4/7] Debootstrap second stage (5–15 min)..."
mount -t proc  proc     "${MOUNT_DIR}/proc"
mount -t sysfs sysfs    "${MOUNT_DIR}/sys"
mount -o bind  /dev     "${MOUNT_DIR}/dev"
mount -o bind  /dev/pts "${MOUNT_DIR}/dev/pts"

chroot "$MOUNT_DIR" /debootstrap/debootstrap --second-stage

# ── Step 5: Configure system ───────────────────────────────────────────────────
log "[5/7] Configuring system..."

# Prevent post-install scripts from starting services inside the chroot.
# invoke-rc.d respects this; exit 101 = "action not allowed".
cat > "${MOUNT_DIR}/usr/sbin/policy-rc.d" <<'EOF'
#!/bin/sh
exit 101
EOF
chmod +x "${MOUNT_DIR}/usr/sbin/policy-rc.d"

# APT sources. The base suite alone doesn't get point-release or security
# fixes after initial release -- those come from the separate -updates and
# -security suites (the latter from a different host entirely; that's normal
# Debian practice, not a mirror-specific thing). Without these, apt never
# shows any updates at all.
cat > "${MOUNT_DIR}/etc/apt/sources.list" <<EOF
deb ${DEBIAN_MIRROR} ${DEBIAN_SUITE} main contrib non-free non-free-firmware
deb-src ${DEBIAN_MIRROR} ${DEBIAN_SUITE} main contrib non-free non-free-firmware

deb ${DEBIAN_MIRROR} ${DEBIAN_SUITE}-updates main contrib non-free non-free-firmware
deb-src ${DEBIAN_MIRROR} ${DEBIAN_SUITE}-updates main contrib non-free non-free-firmware

deb https://security.debian.org/debian-security ${DEBIAN_SUITE}-security main contrib non-free non-free-firmware
deb-src https://security.debian.org/debian-security ${DEBIAN_SUITE}-security main contrib non-free non-free-firmware
EOF

# Keep Recommends on (MATE needs them); never prompt about conffiles.
export DEBIAN_FRONTEND=noninteractive
cat > "${MOUNT_DIR}/etc/apt/apt.conf.d/99build-noninteractive" <<'EOF'
APT::Install-Recommends "1";
Dpkg::Options::= "--force-confold";
EOF

cat > "${MOUNT_DIR}/etc/fstab" <<'EOF'
LABEL=root  /  ext4  errors=remount-ro  0  1
EOF

echo "$HOSTNAME" > "${MOUNT_DIR}/etc/hostname"
cat > "${MOUNT_DIR}/etc/hosts" <<EOF
127.0.0.1   localhost
127.0.1.1   ${HOSTNAME}
EOF

ln -sf "/usr/share/zoneinfo/${TIMEZONE}" "${MOUNT_DIR}/etc/localtime"

# Temporary DNS for the chroot installs; replaced with a static entry at the end
cp /etc/resolv.conf "${MOUNT_DIR}/etc/resolv.conf"

# Locale
echo "en_US.UTF-8 UTF-8" > "${MOUNT_DIR}/etc/locale.gen"
echo 'LANG=en_US.UTF-8' > "${MOUNT_DIR}/etc/default/locale"

# btsdio causes suspend crashes on this hardware
echo "blacklist btsdio" > "${MOUNT_DIR}/etc/modprobe.d/blacklist-btsdio.conf"

# Touchpad: tap-to-click and natural scrolling for X11 sessions.
install -Dm644 "$SCRIPT_DIR/files/etc/X11/xorg.conf.d/30-touchpad.conf" \
    "${MOUNT_DIR}/etc/X11/xorg.conf.d/30-touchpad.conf"

# zram: compressed in-RAM swap — useful even with 4 GB.
install -Dm644 "$SCRIPT_DIR/files/etc/systemd/zram-generator.conf" \
    "${MOUNT_DIR}/etc/systemd/zram-generator.conf"

# ── Step 5b: Install packages ──────────────────────────────────────────────────
log "[5/7] Installing packages (20–40 min)..."

chroot "$MOUNT_DIR" env DEBIAN_FRONTEND=noninteractive apt-get update -q

# ── Initrd ────────────────────────────────────────────────────────────────────
# MODULES=list with a list derived on the target rather than guessed.
#
# The list below is what MODULES=dep produced when run on the booted machine,
# where it traces the real device topology. MODULES=dep cannot be used at
# build time: in an x86 build chroot it traces the host's loop device and
# omits dw_mmc entirely.
#
# Do not trim entries that look unnecessary. An earlier hand-picked four-module
# list left the kernel unable to mount root — it panicked before any console
# existed to say so. Which of the extra modules is decisive was never
# established; the derived list works and MODULES=most also works, at the cost
# of a slower boot. Either is a safe fallback; guessing is not.
#
# To re-derive after a kernel or DTS change, on the booted machine:
#   sed -i 's/^MODULES=.*/MODULES=dep/' /etc/initramfs-tools/initramfs.conf
#   update-initramfs -c -k "$(uname -r)" -b /tmp
#   lsinitramfs /tmp/initrd.img-$(uname -r) | grep '\.ko' | sed 's|.*/||' | sort
# then restore the config.
#
# COMPRESS=gzip: xz silently produced an uncompressed cpio in this chroot.
#
# initramfs-tools is installed before the kernel so these settings apply to the
# first initrd built, rather than arriving after the kernel's postinst.
chroot "$MOUNT_DIR" env DEBIAN_FRONTEND=noninteractive apt-get install -y initramfs-tools
sed -i 's/^MODULES=.*/MODULES=list/'   "${MOUNT_DIR}/etc/initramfs-tools/initramfs.conf"
sed -i 's/^COMPRESS=.*/COMPRESS=gzip/' "${MOUNT_DIR}/etc/initramfs-tools/initramfs.conf"
grep -q '^MODULES=list'  "${MOUNT_DIR}/etc/initramfs-tools/initramfs.conf" || echo 'MODULES=list'  >> "${MOUNT_DIR}/etc/initramfs-tools/initramfs.conf"
grep -q '^COMPRESS=gzip' "${MOUNT_DIR}/etc/initramfs-tools/initramfs.conf" || echo 'COMPRESS=gzip' >> "${MOUNT_DIR}/etc/initramfs-tools/initramfs.conf"

# Appended, not installed: this file belongs to the initramfs-tools package.
cat "$SCRIPT_DIR/files/etc/initramfs-tools/modules" \
    >> "${MOUNT_DIR}/etc/initramfs-tools/modules"


# Kernel: the non-LPAE flavor. This board has no need for LPAE's >4GB
# addressing, and the LPAE flavor was tested and behaved identically.
chroot "$MOUNT_DIR" env DEBIAN_FRONTEND=noninteractive apt-get install -y \
    linux-image-armmp

# Base system. None of this affects whether the image boots — the kernel and
# initrd above are what matter — so it is safe to grow.
# No on-device signing tools needed: U-Boot reads /boot directly, so kernel
# upgrades don't re-sign anything.
chroot "$MOUNT_DIR" env DEBIAN_FRONTEND=noninteractive apt-get install -y \
    sudo locales kbd \
    avahi-daemon systemd-zram-generator \
    vim-tiny less

# WiFi. The C201P has no ethernet port, so this is the machine's only network:
# BCM4354 over SDIO (mmc2). firmware-brcm80211 supplies brcmfmac4354-sdio.bin;
# wireless-regdb supplies regulatory.db (its absence is the "cfg80211: failed
# to load regulatory.db" in dmesg). iw is for debugging from a console.
# NetworkManager pulls in wpasupplicant itself, but name it explicitly so a
# change in NM's dependencies can't silently take WiFi away.
chroot "$MOUNT_DIR" env DEBIAN_FRONTEND=noninteractive apt-get install -y \
    firmware-brcm80211 wireless-regdb \
    wpasupplicant iw

# MATE desktop + display manager. Installed after the WiFi bits so that
# NetworkManager (pulled in by network-manager-gnome) exists before it is
# enabled below. This is by far the largest part of the image and the longest
# part of the build; it has no bearing on whether the machine boots.
chroot "$MOUNT_DIR" env DEBIAN_FRONTEND=noninteractive apt-get install -y \
    mate-desktop-environment \
    mate-desktop-environment-extras \
    lightdm lightdm-gtk-greeter \
    network-manager-gnome \
    firefox-esr
chroot "$MOUNT_DIR" systemctl enable lightdm

# Force backlight on as soon as pwm_bl probes.
# rk3288-veyron.dtsi sets backlight-boot-off so pwm_bl starts with GPIO low
# and PWM=0; the backlight only turns on when DRM calls backlight_enable().
# This udev rule fires the moment any backlight device appears and writes a
# non-zero brightness, lighting the panel regardless of DRM state.
mkdir -p "${MOUNT_DIR}/etc/udev/rules.d"
cat > "${MOUNT_DIR}/etc/udev/rules.d/10-backlight.rules" <<'EOF'
ACTION=="add", SUBSYSTEM=="backlight", ATTR{brightness}="200"
EOF

# Generate locale
chroot "$MOUNT_DIR" locale-gen

# Per-board WiFi NVRAM, which Debian's firmware-brcm80211 does not carry.
#
# Downloaded from ArchLinuxARM below, but originally Google's own
# chromiumos/overlays/board-overlays file
# overlay-veyron/chromeos-base/chromeos-bsp-veyron/files/firmware/brcmfmac4354-sdio.txt
# (commit cef3dd963ffd01f21cf1c9aff3283254a6a0c846).
#
# License: Google's packaging ebuild declares LICENSE="BSD-Google"; we
# assume that's correct. Also shipping the Broadcom LICENCE.broadcom_bcm43xx
# text alongside it for completeness, in case Google is itself
# redistributing under those terms -- probably not strictly necessary.
FIRMWARE_CACHE_DIR="${FIRMWARE_CACHE_DIR:-}"
NVRAM_NAME="brcmfmac4354-sdio.txt"
NVRAM_URL="https://archlinuxarm.org/builder/src/veyron/${NVRAM_NAME}"
NVRAM_MD5="13e41678ae81bdd70b3778fb2dc29662"   # from alarm/firmware-veyron/PKGBUILD
NVRAM_DEST="${MOUNT_DIR}/usr/lib/firmware/updates/brcm"
mkdir -p "$NVRAM_DEST"

if [ -n "$FIRMWARE_CACHE_DIR" ] && [ -f "${FIRMWARE_CACHE_DIR}/${NVRAM_NAME}" ]; then
    log "Using cached veyron NVRAM from ${FIRMWARE_CACHE_DIR}"
    install -m 0644 "${FIRMWARE_CACHE_DIR}/${NVRAM_NAME}" "${NVRAM_DEST}/${NVRAM_NAME}"
else
    log "Fetching veyron BCM4354 NVRAM (${NVRAM_URL})..."
    NVRAM_TMP=$(mktemp)
    NVRAM_ERR=$(mktemp)
    if curl -fsS --retry 3 --retry-delay 5 --connect-timeout 30 \
            -o "$NVRAM_TMP" "$NVRAM_URL" 2>"$NVRAM_ERR"; then
        GOT_MD5=$(md5sum "$NVRAM_TMP" | cut -d" " -f1)
        if [ "$GOT_MD5" = "$NVRAM_MD5" ]; then
            install -m 0644 "$NVRAM_TMP" "${NVRAM_DEST}/${NVRAM_NAME}"
            if [ -n "$FIRMWARE_CACHE_DIR" ]; then
                mkdir -p "$FIRMWARE_CACHE_DIR"
                install -m 0644 "$NVRAM_TMP" "${FIRMWARE_CACHE_DIR}/${NVRAM_NAME}"
            fi
            log "    NVRAM installed (md5 ${GOT_MD5})"
        else
            rm -f "$NVRAM_TMP" "$NVRAM_ERR"
            echo "ERROR: veyron NVRAM checksum mismatch — expected ${NVRAM_MD5}, got ${GOT_MD5}" >&2
            echo "       Refusing to ship an unverified WiFi calibration file. If upstream" >&2
            echo "       genuinely changed, update NVRAM_MD5 in build.sh after checking why." >&2
            exit 1
        fi
    else
        echo "ERROR: veyron NVRAM fetch failed (url: ${NVRAM_URL})" >&2
        sed "s/^/       /" "$NVRAM_ERR" >&2
        rm -f "$NVRAM_TMP" "$NVRAM_ERR"
        exit 1
    fi
    rm -f "$NVRAM_TMP" "$NVRAM_ERR"
fi

{
    echo "== LICENCE.BSD-Google =="
    cat "${SCRIPT_DIR}/licenses/LICENCE.BSD-Google"
    echo
    echo "== LICENCE.broadcom_bcm43xx =="
    cat "${SCRIPT_DIR}/licenses/LICENCE.broadcom_bcm43xx"
} > "$NVRAM_LICENSE_FILE"

# Report what the two sources actually produced. These are the lines to read
# first when WiFi doesn't come up.
log "    firmware/brcm (from firmware-brcm80211): $(ls "${MOUNT_DIR}/usr/lib/firmware/brcm/" 2>/dev/null | grep -i 4354 | tr '\n' ' ')"
log "    firmware/updates/brcm (veyron NVRAM):    $(ls "${NVRAM_DEST}" 2>/dev/null | tr '\n' ' ')"

WIFI_BIN=""
for d in "${MOUNT_DIR}/usr/lib/firmware/brcm" "${MOUNT_DIR}/usr/lib/firmware/updates/brcm"; do
    [ -f "${d}/brcmfmac4354-sdio.bin" ] && WIFI_BIN="${d}/brcmfmac4354-sdio.bin"
done
if [ -n "$WIFI_BIN" ] && [ -f "${NVRAM_DEST}/${NVRAM_NAME}" ]; then
    log "    WiFi firmware check: OK (.bin and NVRAM .txt both present)"
elif [ -n "$WIFI_BIN" ]; then
    log "    WiFi firmware check: .bin present, NVRAM .txt MISSING — WiFi may be unreliable."
else
    log "    WiFi firmware check: MISSING brcmfmac4354-sdio.bin — WiFi will NOT work."
    log "      Expected it from the firmware-brcm80211 package. Check that it installed,"
    log "      and that non-free-firmware is enabled in sources.list."
fi

# Networking: NetworkManager owns every interface (WiFi and any USB-ethernet
# dongle). systemd-networkd is deliberately NOT enabled — running both makes
# them fight over the same interfaces. avahi puts the machine on c201.local.
chroot "$MOUNT_DIR" systemctl enable NetworkManager
chroot "$MOUNT_DIR" systemctl enable systemd-resolved 2>/dev/null || true

# Clean the package cache to shrink the image
chroot "$MOUNT_DIR" apt-get clean

# ── Step 5c: Users ─────────────────────────────────────────────────────────────
log "[5/7] Creating user '${USERNAME}'..."
echo "root:${ROOT_PASSWORD}" | chroot "$MOUNT_DIR" chpasswd
chroot "$MOUNT_DIR" useradd -m -G sudo,audio,video,plugdev,netdev -s /bin/bash "$USERNAME"
echo "${USERNAME}:${PASSWORD}" | chroot "$MOUNT_DIR" chpasswd

# ── Step 5d: Kernel hooks — keep extlinux.conf current ────────────────────────
# U-Boot reads /boot directly, so a kernel upgrade needs NO re-signing: just
# refresh extlinux.conf and the DTB. The signed KERN-A holds U-Boot, which
# never changes.
#
# The same script runs on install and on removal — it regenerates the config
# from whatever kernels are actually in /boot, listing each one so U-Boot can
# fall back to an older kernel if the newest fails to load.
for d in postinst.d postrm.d; do
    install -Dm755 "$SCRIPT_DIR/files/etc/kernel/postinst.d/zz-update-extlinux" \
        "${MOUNT_DIR}/etc/kernel/${d}/zz-update-extlinux"
done

# ── Step 6: Write the U-Boot kpart to KERN-A and configure extlinux boot ──────
# U-Boot was built and signed in Step 0. Write it to KERN-A, then drop the
# extlinux.conf that U-Boot reads from the ext4 root to locate and boot Linux.
log "[6/7] Writing U-Boot kpart and configuring extlinux boot..."

KVER=$(ls "${MOUNT_DIR}/boot/vmlinuz-"* | sort -V | tail -1 | sed "s|${MOUNT_DIR}/boot/vmlinuz-||")
log "    Kernel: ${KVER}"
log "    Initrd: $(du -sh "${MOUNT_DIR}/boot/initrd.img-${KVER}" | cut -f1)  (MODULES=list, target-derived, gzip)"

# The modules named in /etc/initramfs-tools/modules are not always the modules
# that end up in the initrd — a broken hook once produced an empty one. Fail
# here rather than at boot, where this hardware reports nothing at all.
INITRD_MODS=$(chroot "$MOUNT_DIR" lsinitramfs "/boot/initrd.img-${KVER}" 2>/dev/null \
    | grep -E '\.ko' | sed 's|.*/||; s/\.ko.*//' | tr '-' '_' | sort -u)
INITRD_MISSING=""
for m in dw_mmc_rockchip dw_mmc_pltfm ext4 i2c_rk3x rk808_regulator; do
    printf '%s\n' "$INITRD_MODS" | grep -qx "$m" || INITRD_MISSING="${INITRD_MISSING} ${m}"
done
if [ -n "$INITRD_MISSING" ]; then
    echo "ERROR: initrd is missing required module(s):${INITRD_MISSING}" >&2
    echo "       Without these the kernel panics before mounting root, silently," >&2
    echo "       with no console output. See the initrd section of build.sh." >&2
    exit 1
fi
log "    initrd module check: OK"

# Install the DTB and write extlinux.conf by running the kernel postinst hook
# installed above, rather than repeating it here — one definition, and the
# upgrade path gets exercised at build time.
chroot "$MOUNT_DIR" /etc/kernel/postinst.d/zz-update-extlinux "$KVER"
[ -f "${MOUNT_DIR}/boot/extlinux/extlinux.conf" ] \
    || { echo "ERROR: extlinux.conf was not created" >&2; exit 1; }
[ -f "${MOUNT_DIR}/boot/rk3288-veyron-speedy.dtb" ] \
    || { echo "ERROR: DTB was not installed" >&2; exit 1; }

# Write the signed U-Boot (built in Step 0) to KERN-A.
KPART_BYTES=$(stat -c%s "$UBOOT_KPART")
KERN_PART_BYTES=$(( 64 * 1024 * 1024 ))
log "    U-Boot kpart: $(du -sh "$UBOOT_KPART" | cut -f1) (KERN-A partition: 64 MB)"
[ "$KPART_BYTES" -le "$KERN_PART_BYTES" ] \
    || { echo "ERROR: U-Boot kpart (${KPART_BYTES} B) exceeds KERN-A (${KERN_PART_BYTES} B)" >&2; exit 1; }
dd if="$UBOOT_KPART" of="$PART1" bs=1M
cp "$UBOOT_KPART" "$UBOOT_KPART_FILE"
rm -f "$UBOOT_KPART"
log "    U-Boot kpart written to KERN-A and saved standalone: ${UBOOT_KPART_FILE}"

cp "${SCRIPT_DIR}/licenses/LICENCE.GPL-2.0" "$UBOOT_LICENSE_FILE"
log "    U-Boot license saved: ${UBOOT_LICENSE_FILE}"

log "    extlinux.conf and DTB written"

# ── Step 7: Finalise ───────────────────────────────────────────────────────────
log "[7/7] Finalising..."

# Write a build marker — mount the ROOTFS partition and cat /boot/BUILD_STAMP
# to verify the image was written correctly before chasing boot issues.
BUILD_STAMP_FILE="${MOUNT_DIR}/boot/BUILD_STAMP"
printf 'build:  uboot-chainload extlinux target-derived-initrd mate-desktop wifi\ncommit: %s\nbuilt:  %s\nkernel: %s\n' \
    "$(git -C "$SCRIPT_DIR" rev-parse HEAD 2>/dev/null || echo unknown)" \
    "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    "$KVER" \
    > "$BUILD_STAMP_FILE"
log "    Build stamp: $(cat "$BUILD_STAMP_FILE" | tr '\n' ' ')"
log "    /boot contents:"
ls -lh "${MOUNT_DIR}/boot/"

# Zero free space so xz gets a much better compression ratio
log "    Zeroing free space (improves xz ratio)..."
dd if=/dev/zero of="${MOUNT_DIR}/ZEROES" bs=1M 2>/dev/null || true
rm -f "${MOUNT_DIR}/ZEROES"
sync

# Leave a static resolv.conf rather than the build host's one
echo "nameserver 1.1.1.1" > "${MOUNT_DIR}/etc/resolv.conf"

# Remove the apt config override, policy-rc.d, and qemu stub
rm -f "${MOUNT_DIR}/etc/apt/apt.conf.d/99build-noninteractive"
rm -f "${MOUNT_DIR}/usr/sbin/policy-rc.d"
rm -f "${MOUNT_DIR}/usr/bin/qemu-arm-static"

# Explicit unmount before the trap fires (cleaner for sync)
for sub in dev/pts dev sys proc; do
    umount "${MOUNT_DIR}/${sub}" 2>/dev/null || true
done
umount "$MOUNT_DIR"
losetup -d "$LOOP_DEV"
LOOP_DEV=""
sync

# ── Done ───────────────────────────────────────────────────────────────────────
cat <<EOF

════════════════════════════════════════════════════════════════
  Image built: ${IMAGE_FILE}
  U-Boot kpart: ${UBOOT_KPART_FILE} (signed, KERN-A only -- flash with cgpt/dd)
  U-Boot license: ${UBOOT_LICENSE_FILE} (GPL-2.0; this project's own code is ISC, see LICENSE)

  Default login: ${USERNAME} / ${PASSWORD}
  Root login:    root / ${ROOT_PASSWORD}
  → Change both passwords on first boot.

  To expand the root partition after flashing a larger card:
    sudo growpart /dev/mmcblk1 2
    sudo resize2fs /dev/mmcblk1p2

  Kernel updates: just apt upgrade and reboot. U-Boot reads /boot directly,
  so no re-signing is needed (the zz-update-extlinux hook refreshes config).
════════════════════════════════════════════════════════════════
EOF
