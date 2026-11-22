#!/usr/bin/env bash
#
# Linux-recovery for Samsung Galaxy A70 (a70q): a kernel + tiny busybox
# initramfs flashed to the RECOVERY partition. It boots a normal GNU/Linux
# rootfs from /data/linux.img or from a microSD partition labelled LINUX.
# Android stays on BOOT -> dual boot.
#
#   ./build_linux_recovery.sh                     build out-recovery/linux-recovery-*.img
#   LIKE_IMG=twrp.img ./build_linux_recovery.sh   copy header (cmdline, os_version,
#                                                 recovery_dtbo, ...) from an image
#                                                 that already boots on your phone
#
# Environment: same as build_nethunter.sh, plus
#   LIKE_IMG        reference recovery/TWRP image (recommended)
#   RECOVERY_DTBO   dtbo.img to embed when LIKE_IMG is not given
#                   (default: a70q TWRP device tree prebuilt dtbo)
#   OS_VERSION / OS_PATCH_LEVEL   header values without LIKE_IMG
#                   (default 11.0.0 / 2025-12, like the a70q TWRP)
#
set -euo pipefail

KDIR="$(cd "$(dirname "$0")" && pwd)"
cd "$KDIR"
LR="$KDIR/linux-recovery"
export OUT="${OUT:-$KDIR/out-recovery}"
export EXTRA_FRAGMENTS="linux-recovery/recovery.config"
DL="$KDIR/toolchain/downloads"

BUSYBOX_DEB="busybox-static_1.37.0-7ubuntu1.1_arm64.deb"
BUSYBOX_URL="http://ports.ubuntu.com/ubuntu-ports/pool/main/b/busybox/$BUSYBOX_DEB"
BUSYBOX_SHA256="a2d4110fb03c9e558e98aff6f5220d112cd55a8211e9ea9aaeea06b9d4ccb5f7"
DTBO_URL="https://raw.githubusercontent.com/samsung-sm6150-devs/android_device_samsung_a70q-twrp/52216ac27852f3bf932763917893897d7f3948b3/prebuilt/dtbo.img"
DTBO_SHA256="${DTBO_SHA256:-}"

msg() { printf '\n\e[1;93m[*] %s\e[0m\n' "$*"; }
err() { printf '\n\e[1;31m[x] %s\e[0m\n' "$*" >&2; exit 1; }

# 1. kernel -------------------------------------------------------------------
"$KDIR/build_nethunter.sh" kernel

# 2. busybox (static arm64) -----------------------------------------------------
mkdir -p "$DL"
if [ ! -x "$DL/busybox" ]; then
    msg "Downloading static arm64 busybox"
    curl -sfL -o "$DL/$BUSYBOX_DEB" "$BUSYBOX_URL"
    echo "$BUSYBOX_SHA256  $DL/$BUSYBOX_DEB" | sha256sum -c -
    tmp="$(mktemp -d)"
    (cd "$tmp" && ar x "$DL/$BUSYBOX_DEB")
    data="$(ls "$tmp"/data.tar.*)"
    case "$data" in
        *.zst) if command -v zstd >/dev/null; then zstd -dc "$data" > "$tmp/data.tar"
               else python3 -c "import sys,zstandard;sys.stdout.buffer.write(zstandard.ZstdDecompressor().stream_reader(open(sys.argv[1],'rb')).read())" "$data" > "$tmp/data.tar"; fi ;;
        *)     tar -xf "$data" -C "$tmp" ./usr/bin/busybox ;;
    esac
    [ -f "$tmp/data.tar" ] && tar -xf "$tmp/data.tar" -C "$tmp" ./usr/bin/busybox
    install -m755 "$tmp/usr/bin/busybox" "$DL/busybox"
    rm -rf "$tmp"
fi

# 3. initramfs ------------------------------------------------------------------
msg "Building initramfs"
GEN="$OUT/usr/gen_init_cpio"
[ -x "$GEN" ] || err "gen_init_cpio missing (kernel build did not run?)"
LIST="$OUT/linux-recovery.cpio.list"
cat > "$LIST" <<EOF
dir /dev 0755 0 0
nod /dev/console 0600 0 0 c 5 1
nod /dev/null 0666 0 0 c 1 3
dir /bin 0755 0 0
dir /sbin 0755 0 0
dir /usr 0755 0 0
dir /usr/bin 0755 0 0
dir /usr/sbin 0755 0 0
dir /proc 0755 0 0
dir /sys 0755 0 0
dir /data 0755 0 0
dir /new_root 0755 0 0
dir /tmp 1777 0 0
dir /run 0755 0 0
file /bin/busybox $DL/busybox 0755 0 0
slink /bin/sh busybox 0777 0 0
file /init $LR/init 0755 0 0
EOF
"$GEN" "$LIST" | gzip -9n > "$OUT/initramfs.cpio.gz"

# 4. recovery.img ----------------------------------------------------------------
KREL="$(cat "$OUT/include/config/kernel.release")"
BRANCH="$(git -C "$KDIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo src)"
case "$BRANCH" in lineage-*) TAG="$BRANCH" ;; *) TAG="stock-11" ;; esac
IMG="$OUT/linux-recovery-a70q-$TAG-$(date +%Y%m%d).img"
ARGS=(--kernel "$OUT/arch/arm64/boot/Image.gz-dtb" --ramdisk "$OUT/initramfs.cpio.gz"
      --out "$IMG" --append-cmdline "rdinit=/init")
if [ -n "${LIKE_IMG:-}" ]; then
    msg "Copying header from $LIKE_IMG"
    ARGS+=(--like "$LIKE_IMG")
else
    if [ -z "${RECOVERY_DTBO:-}" ]; then
        RECOVERY_DTBO="$DL/a70q-dtbo.img"
        [ -f "$RECOVERY_DTBO" ] || curl -sfL -o "$RECOVERY_DTBO" "$DTBO_URL"
        [ -z "$DTBO_SHA256" ] || echo "$DTBO_SHA256  $RECOVERY_DTBO" | sha256sum -c -
    fi
    ARGS+=(--recovery_dtbo "$RECOVERY_DTBO"
           --os_version "${OS_VERSION:-11.0.0}" --os_patch_level "${OS_PATCH_LEVEL:-2025-12}")
fi
python3 "$LR/mkbootimg.py" "${ARGS[@]}"
python3 "$LR/mkbootimg.py" --info "$IMG"
# Odin wants a tar with the partition image named recovery.img
ODIN_DIR="$(mktemp -d)"
cp "$IMG" "$ODIN_DIR/recovery.img"
tar -C "$ODIN_DIR" -cf "${IMG%.img}-odin.tar" recovery.img
rm -rf "$ODIN_DIR"
msg "Done: ${IMG#$KDIR/} and $(basename "${IMG%.img}")-odin.tar  (kernel $KREL)"
