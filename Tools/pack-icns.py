#!/usr/bin/env python3
"""Puts an iconset's PNGs into an .icns exactly as they are.

iconutil re-encodes every PNG it packs, which undoes build.sh's lossless compression (oxipng: the
same pixels in about 20% fewer bytes). So iconutil still lays out the .icns (it picks the entry
types and writes the 16 and 32 pixel ones as raw ARGB), and this swaps each PNG entry for the
iconset's PNG of the same pixel size.

  pack-icns.py <icns from iconutil> <iconset dir> <out.icns> [--max-px N]

--max-px N leaves out the PNG entries larger than N pixels (for the disk image's volume icon).
"""
import os
import struct
import sys

PNG_MAGIC = b"\x89PNG\r\n\x1a\n"


def png_width(data):
    return struct.unpack(">I", data[16:20])[0]


def main():
    args = sys.argv[1:]
    max_px = None
    if "--max-px" in args:
        i = args.index("--max-px")
        max_px = int(args[i + 1])
        del args[i:i + 2]
    if len(args) != 3:
        sys.exit(__doc__)
    src, iconset, out = args

    # Several iconset files share a pixel size (icon_128x128@2x and icon_256x256); they are the same picture.
    pngs = {}
    for name in os.listdir(iconset):
        if name.endswith(".png"):
            with open(os.path.join(iconset, name), "rb") as f:
                data = f.read()
            pngs[png_width(data)] = data

    with open(src, "rb") as f:
        icns = f.read()
    if icns[:4] != b"icns":
        sys.exit(f"pack-icns: {src} is not an .icns file")
    entries = []
    pos = 8
    while pos < len(icns):
        kind = icns[pos:pos + 4]
        length = struct.unpack(">I", icns[pos + 4:pos + 8])[0]
        body = icns[pos + 8:pos + length]
        pos += length
        if body[:8] == PNG_MAGIC:
            px = png_width(body)
            if max_px is not None and px > max_px:
                continue
            if px not in pngs:
                sys.exit(f"pack-icns: {iconset} has no {px}x{px} PNG for entry {kind.decode()}")
            body = pngs[px]
        entries.append(kind + struct.pack(">I", len(body) + 8) + body)

    blob = b"".join(entries)
    with open(out, "wb") as f:
        f.write(b"icns" + struct.pack(">I", len(blob) + 8) + blob)


if __name__ == "__main__":
    main()
