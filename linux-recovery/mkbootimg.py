#!/usr/bin/env python3
"""
Minimal Android boot/recovery image packer (header v0/v1/v2) for the
Galaxy A70 (a70q) Linux-recovery.

Defaults match the a70q recovery (TWRP device tree): header v1, page 4096,
base 0x0, kernel 0x8000, ramdisk 0x2000000, tags 0x1e00000, recovery_dtbo.

  mkbootimg.py --kernel Image.gz-dtb --ramdisk initramfs.cpio.gz \
               --recovery_dtbo dtbo.img --out recovery.img

  # or copy every header field (cmdline, os_version, offsets, page size and
  # the embedded recovery_dtbo) from an image that already boots on the phone
  # (TWRP or stock recovery.img), replacing only kernel + ramdisk:
  mkbootimg.py --like twrp.img --kernel ... --ramdisk ... --out recovery.img

  mkbootimg.py --info recovery.img
"""
import argparse
import hashlib
import struct
import sys

BOOT_MAGIC = b"ANDROID!"
SEANDROID = b"SEANDROIDENFORCE"

A70_CMDLINE = (
    "console=null androidboot.hardware=qcom androidboot.memcg=1 "
    "lpm_levels.sleep_disabled=1 msm_rtb.filter=0x237 service_locator.enable=1 "
    "swiotlb=1 androidboot.usbcontroller=a600000.dwc3 "
    "firmware_class.path=/vendor/firmware_mnt/image nokaslr printk.devkmsg=on"
)


def pad(n, page):
    return (page - n % page) % page


def os_version_field(version, patch):
    a, b, c = (int(x) for x in (version.split(".") + ["0", "0"])[:3])
    y, m = (int(x) for x in patch.split("-")[:2])
    return ((a << 14) | (b << 7) | c) << 11 | ((y - 2000) << 4) | m


def parse(path):
    d = open(path, "rb").read()
    if d[:8] != BOOT_MAGIC:
        sys.exit(f"{path}: not an Android boot image")
    f = dict(zip(
        ["kernel_size", "kernel_addr", "ramdisk_size", "ramdisk_addr",
         "second_size", "second_addr", "tags_addr", "page_size",
         "header_version", "os_version"],
        struct.unpack_from("<10I", d, 8)))
    f["name"] = d[48:64].split(b"\0")[0]
    f["cmdline"] = d[64:576].split(b"\0")[0] + d[608:1632].split(b"\0")[0]
    ps = f["page_size"]
    off = ps
    f["kernel"] = d[off:off + f["kernel_size"]]
    off += f["kernel_size"] + pad(f["kernel_size"], ps)
    f["ramdisk"] = d[off:off + f["ramdisk_size"]]
    off += f["ramdisk_size"] + pad(f["ramdisk_size"], ps)
    f["second"] = d[off:off + f["second_size"]]
    off += f["second_size"] + pad(f["second_size"], ps)
    f["recovery_dtbo"] = b""
    f["dtb"] = b""
    if f["header_version"] >= 1:
        rsz, roff = struct.unpack_from("<IQ", d, 1632)
        if rsz:
            f["recovery_dtbo"] = d[roff:roff + rsz]
            off = roff + rsz + pad(rsz, ps)
    if f["header_version"] >= 2:
        dsz, daddr = struct.unpack_from("<IQ", d, 1648)
        f["dtb_addr"] = daddr
        f["dtb"] = d[off:off + dsz]
    return f


def build(a):
    like = parse(a.like) if a.like else None
    page = a.page_size or (like["page_size"] if like else 4096)
    hv = a.header_version if a.header_version is not None else (
        like["header_version"] if like else 1)
    base = a.base
    kaddr = like["kernel_addr"] if like and a.keep_addrs else base + a.kernel_offset
    raddr = like["ramdisk_addr"] if like and a.keep_addrs else base + a.ramdisk_offset
    saddr = like["second_addr"] if like and a.keep_addrs else base + a.second_offset
    taddr = like["tags_addr"] if like and a.keep_addrs else base + a.tags_offset

    kernel = open(a.kernel, "rb").read()
    ramdisk = open(a.ramdisk, "rb").read()
    second = b""
    rdtbo = open(a.recovery_dtbo, "rb").read() if a.recovery_dtbo else (
        like["recovery_dtbo"] if like else b"")
    dtb = open(a.dtb, "rb").read() if a.dtb else (like["dtb"] if like else b"")
    if hv == 1 and not rdtbo:
        print("warning: header v1 without recovery_dtbo", file=sys.stderr)

    if a.os_version:
        osv = os_version_field(a.os_version, a.os_patch_level)
    elif like:
        osv = like["os_version"]
    else:
        osv = os_version_field("11.0.0", "2025-12")

    cmdline = (a.cmdline if a.cmdline is not None else
               (like["cmdline"].decode() if like else A70_CMDLINE))
    if a.append_cmdline:
        cmdline = (cmdline + " " + a.append_cmdline).strip()
    cb = cmdline.encode()
    if len(cb) > 512 + 1024 - 2:
        sys.exit("cmdline too long")
    c1, c2 = cb[:511], cb[511:]

    sha = hashlib.sha1()
    for blob in (kernel, ramdisk, second):
        sha.update(blob)
        sha.update(struct.pack("<I", len(blob)))
    if hv >= 1:
        sha.update(rdtbo)
        sha.update(struct.pack("<I", len(rdtbo)))
    if hv >= 2:
        sha.update(dtb)
        sha.update(struct.pack("<I", len(dtb)))
    img_id = sha.digest().ljust(32, b"\0")

    def page_off(*sizes):
        o = page
        for s in sizes:
            o += s + pad(s, page)
        return o

    hdr = BOOT_MAGIC + struct.pack(
        "<10I", len(kernel), kaddr, len(ramdisk), raddr, len(second), saddr,
        taddr, page, hv, osv)
    name = a.name.encode() if a.name else (like["name"] if like else b"")
    hdr += name[:15].ljust(16, b"\0")
    hdr += c1.ljust(512, b"\0")
    hdr += img_id
    hdr += c2.ljust(1024, b"\0")
    if hv >= 1:
        rdtbo_off = page_off(len(kernel), len(ramdisk), len(second)) if rdtbo else 0
        hdr += struct.pack("<IQ", len(rdtbo), rdtbo_off)
        hsize = 1648 if hv == 1 else 1660
        if hv >= 2:
            hsize = 1660
        hdr += struct.pack("<I", hsize)
    if hv >= 2:
        hdr += struct.pack("<IQ", len(dtb), like.get("dtb_addr", base + 0x01f00000) if like else base + 0x01f00000)

    out = bytearray(hdr + b"\0" * pad(len(hdr), page))
    for blob in (kernel, ramdisk, second, rdtbo if hv >= 1 else b"", dtb if hv >= 2 else b""):
        if blob:
            out += blob + b"\0" * pad(len(blob), page)
    if not a.no_seandroid:
        out += SEANDROID
    open(a.out, "wb").write(out)
    print(f"{a.out}: header v{hv}, page {page}, kernel {len(kernel)}, "
          f"ramdisk {len(ramdisk)}, recovery_dtbo {len(rdtbo)}, cmdline {len(cb)} B")


def info(path):
    f = parse(path)
    osv = f["os_version"]
    ver = f"{osv >> 25}.{(osv >> 18) & 0x7f}.{(osv >> 11) & 0x7f}"
    patch = f"{((osv >> 4) & 0x7f) + 2000}-{osv & 0xf:02d}"
    for k in ("header_version", "page_size", "kernel_size", "ramdisk_size",
              "second_size"):
        print(f"{k:16} {f[k]}")
    for k in ("kernel_addr", "ramdisk_addr", "second_addr", "tags_addr"):
        print(f"{k:16} 0x{f[k]:08x}")
    print(f"{'recovery_dtbo':16} {len(f['recovery_dtbo'])}")
    print(f"{'os_version':16} {ver} / {patch}")
    print(f"{'cmdline':16} {f['cmdline'].decode(errors='replace')}")


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--info", metavar="IMG")
    p.add_argument("--like", metavar="IMG", help="copy header fields from this image")
    p.add_argument("--keep-addrs", action="store_true", default=True)
    p.add_argument("--kernel")
    p.add_argument("--ramdisk")
    p.add_argument("--recovery_dtbo")
    p.add_argument("--dtb")
    p.add_argument("--out")
    p.add_argument("--cmdline")
    p.add_argument("--append-cmdline", default="")
    p.add_argument("--header_version", type=int)
    p.add_argument("--page_size", type=int)
    p.add_argument("--base", type=lambda x: int(x, 0), default=0x00000000)
    p.add_argument("--kernel_offset", type=lambda x: int(x, 0), default=0x00008000)
    p.add_argument("--ramdisk_offset", type=lambda x: int(x, 0), default=0x02000000)
    p.add_argument("--second_offset", type=lambda x: int(x, 0), default=0x00f00000)
    p.add_argument("--tags_offset", type=lambda x: int(x, 0), default=0x01e00000)
    p.add_argument("--os_version")
    p.add_argument("--os_patch_level", default="2025-12")
    p.add_argument("--name", default="")
    p.add_argument("--no-seandroid", action="store_true")
    a = p.parse_args()
    if a.info:
        return info(a.info)
    if not (a.kernel and a.ramdisk and a.out):
        p.error("--kernel, --ramdisk and --out are required")
    build(a)


if __name__ == "__main__":
    main()
