#!/usr/bin/env bash
#
# NetHunter kernel build for Samsung Galaxy A70 (a70q, SM-A705F/FN)
#
#   ./build_nethunter.sh            -> config + kernel + modules + AnyKernel3 zip
#   ./build_nethunter.sh config     -> only generate out/.config and verify it
#
# Environment overrides:
#   BASE_DEFCONFIG   base defconfig in arch/arm64/configs (default per branch)
#   CLANG_DIR        toolchain with bin/clang + aarch64-linux-gnu-* binutils
#                    (default: ./toolchain/proton-clang, cloned if missing)
#   JOBS             parallel jobs (default: nproc)
#   ZIP_NAME         output zip name
#
set -euo pipefail

KDIR="$(cd "$(dirname "$0")" && pwd)"
cd "$KDIR"

# stock-11 ships nethunter_defconfig, lineage-20 ships neternels_defconfig.
if [ -z "${BASE_DEFCONFIG:-}" ]; then
    for c in nethunter_defconfig neternels_defconfig a70q_defconfig; do
        [ -f "arch/arm64/configs/$c" ] && BASE_DEFCONFIG="$c" && break
    done
fi
: "${BASE_DEFCONFIG:?no base defconfig found}"
EXTRAS="arch/arm64/configs/nethunter-extras.config"
CLANG_DIR="${CLANG_DIR:-$KDIR/toolchain/proton-clang}"
AK3_DIR="${AK3_DIR:-$KDIR/toolchain/anykernel3}"
JOBS="${JOBS:-$(nproc)}"
OUT="${OUT:-$KDIR/out}"
# Extra config fragments merged after nethunter-extras (space separated,
# relative to the tree), e.g. linux-recovery/recovery.config
EXTRA_FRAGMENTS="${EXTRA_FRAGMENTS:-}"

msg() { printf '\n\e[1;93m[*] %s\e[0m\n' "$*"; }
err() { printf '\n\e[1;31m[x] %s\e[0m\n' "$*" >&2; exit 1; }

if [ ! -x "$CLANG_DIR/bin/clang" ]; then
    msg "Cloning proton-clang toolchain"
    git clone --depth=1 https://github.com/kdrag0n/proton-clang "$CLANG_DIR"
fi
# Appended (not prepended): proton ships its own x86 "ld" that must not
# shadow the host linker used for HOSTCC tools.
export PATH="$PATH:$CLANG_DIR/bin"
TC="$CLANG_DIR/bin"
export KBUILD_BUILD_USER="${KBUILD_BUILD_USER:-J4n3K}"
export KBUILD_BUILD_HOST="${KBUILD_BUILD_HOST:-NetHunter}"
export KBUILD_COMPILER_STRING
KBUILD_COMPILER_STRING="$("$TC/clang" --version | head -n1 | sed 's/(https.*//;s/ version//')"

# clang for C, GNU binutils (from the same toolchain) for linking,
# the same split the upstream build scripts use.
MAKE=(make -C "$KDIR" O="$OUT" ARCH=arm64
      CC="$TC/clang" AR="$TC/llvm-ar" NM="$TC/llvm-nm"
      OBJCOPY="$TC/llvm-objcopy" OBJDUMP="$TC/llvm-objdump" STRIP="$TC/llvm-strip"
      CLANG_TRIPLE=aarch64-linux-gnu-
      CROSS_COMPILE="$TC/aarch64-linux-gnu-"
      CROSS_COMPILE_ARM32="$TC/arm-linux-gnueabi-"
      CONFIG_BUILD_ARM64_DT_OVERLAY=y)

# Samsung trees ship a prebuilt dtc in tools/ that supports overlays.
[ -x "$KDIR/tools/dtc" ] && MAKE+=(DTC_EXT="$KDIR/tools/dtc")

gen_config() {
    local frags=("$KDIR/$EXTRAS") f
    for f in $EXTRA_FRAGMENTS; do frags+=("$KDIR/$f"); done
    msg "Generating config: $BASE_DEFCONFIG + ${frags[*]#$KDIR/}"
    mkdir -p "$OUT"
    "${MAKE[@]}" "$BASE_DEFCONFIG"
    KCONFIG_CONFIG="$OUT/.config" "$KDIR/scripts/kconfig/merge_config.sh" \
        -m -O "$OUT" "$OUT/.config" "${frags[@]}"
    "${MAKE[@]}" olddefconfig

    # Expected values: last definition of each option across all fragments.
    local want_file="$OUT/.nethunter-want"
    cat "${frags[@]}" | awk '
        /^CONFIG_[A-Za-z0-9_]+=/ { split($0, a, "="); o = a[1] }
        /^# CONFIG_[A-Za-z0-9_]+ is not set/ { o = $2 }
        o != "" { if (!(o in v)) ord[n++] = o; v[o] = $0; o = "" }
        END { for (i = 0; i < n; i++) print v[ord[i]] }' > "$want_file"

    msg "Verifying requested options"
    local bad=0 line opt want got
    while IFS= read -r line; do
        case "$line" in
            CONFIG_*=*) opt="${line%%=*}"; want="${line#*=}" ;;
            "# CONFIG_"*" is not set") opt="${line#\# }"; opt="${opt%% *}"; want="n" ;;
            *) continue ;;
        esac
        got="$(grep -E "^${opt}=" "$OUT/.config" | cut -d= -f2- || true)"
        [ -z "$got" ] && got=n
        if [ "$got" != "$want" ]; then
            # Options that do not exist on this branch are only a warning.
            if grep -rqE "^\s*(menu)?config ${opt#CONFIG_}\s*$" --include='Kconfig*' "$KDIR" 2>/dev/null; then
                printf '  MISMATCH %-40s want=%s got=%s\n' "$opt" "$want" "$got"; bad=1
            else
                printf '  (absent) %-40s not in this tree\n' "$opt"
            fi
        fi
    done < "$want_file"
    [ "$bad" = 0 ] || err "Some options did not apply (missing dependencies?)"
    printf '  all present options applied\n'
}

build() {
    msg "Building kernel with $KBUILD_COMPILER_STRING ($JOBS jobs)"
    "${MAKE[@]}" -j"$JOBS"
    [ -f "$OUT/arch/arm64/boot/Image.gz-dtb" ] || err "Image.gz-dtb not produced"

    msg "Building and installing modules"
    rm -rf "$OUT/modules_install"
    "${MAKE[@]}" -j"$JOBS" modules
    "${MAKE[@]}" INSTALL_MOD_PATH="$OUT/modules_install" INSTALL_MOD_STRIP=1 modules_install
}

package() {
    msg "Packaging AnyKernel3 zip"
    if [ ! -f "$AK3_DIR/anykernel.sh" ]; then
        git clone --depth=1 -b a70q https://github.com/MrRob0-X/anykernel3 "$AK3_DIR"
    fi
    local stage="$OUT/ak3"
    rm -rf "$stage"; cp -r "$AK3_DIR" "$stage"; rm -rf "$stage/.git"
    cp "$OUT/arch/arm64/boot/Image.gz-dtb" "$stage/"
    sed -i "s/^kernel.string=.*/kernel.string=NetHunter kernel for Galaxy A70 by J4n3K (${BASE_DEFCONFIG%_defconfig})/" "$stage/anykernel.sh"

    # Ship loadable modules (e.g. 8188eu.ko) inside the zip for Magisk/NetHunter.
    local kver mods
    kver="$(cat "$OUT/include/config/kernel.release")"
    mods="$(find "$OUT/modules_install" -name '*.ko' 2>/dev/null || true)"
    if [ -n "$mods" ]; then
        mkdir -p "$stage/modules/vendor/lib/modules/$kver"
        # shellcheck disable=SC2086
        cp $mods "$stage/modules/vendor/lib/modules/$kver/"
        cp $mods "$stage/modules/vendor/lib/modules/"
        sed -i 's/^do.modules=.*/do.modules=1/' "$stage/anykernel.sh"
    fi

    local name="${ZIP_NAME:-NetHunter-a70q-${BASE_DEFCONFIG%_defconfig}-$(date +%Y%m%d-%H%M).zip}"
    (cd "$stage" && zip -qr9 "$OUT/$name" . -x '.git*' 'README.md')
    cp "$OUT/.config" "$OUT/${name%.zip}.config"
    msg "Done: out/$name"
}

case "${1:-all}" in
    config) gen_config ;;
    kernel) gen_config; build ;;
    all)    gen_config; build; package ;;
    *) err "usage: $0 [all|config|kernel]" ;;
esac
