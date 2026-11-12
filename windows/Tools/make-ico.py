#!/usr/bin/env python3
"""Packs PNG files into a Windows .ico (PNG-compressed entries, supported since Vista).

Usage: make-ico.py <out.ico> <png>...   (each PNG must be square; sizes up to 256)

The source art for FiveT is ../Resources/AppIcon-source.png. On macOS, resize it with
`sips -z N N src.png --out icon_N.png` for N in 16 24 32 48 64 128 256; on Windows use
any image tool. Standard library only, so it runs anywhere.
"""
import struct
import sys


def png_size(data: bytes) -> int:
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise SystemExit("not a PNG")
    w, h = struct.unpack(">II", data[16:24])
    if w != h:
        raise SystemExit(f"PNG is {w}x{h}, needs to be square")
    return w


def main() -> None:
    if len(sys.argv) < 3:
        raise SystemExit(__doc__)
    out, files = sys.argv[1], sys.argv[2:]
    images = []
    for f in files:
        with open(f, "rb") as fh:
            data = fh.read()
        images.append((png_size(data), data))
    images.sort(key=lambda t: t[0])
    header = struct.pack("<HHH", 0, 1, len(images))
    offset = len(header) + 16 * len(images)
    entries, blobs = b"", b""
    for size, data in images:
        dim = 0 if size >= 256 else size   # 0 means 256 in the directory
        entries += struct.pack("<BBBBHHII", dim, dim, 0, 0, 1, 32, len(data), offset)
        blobs += data
        offset += len(data)
    with open(out, "wb") as fh:
        fh.write(header + entries + blobs)
    print(f"wrote {out}: {', '.join(str(s) for s, _ in images)} px")


if __name__ == "__main__":
    main()
