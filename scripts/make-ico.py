#!/usr/bin/env python3
"""Pack PNG files into a Windows .ico.

Windows (Vista+) accepts PNG-compressed entries directly, so this is a pure
container operation, no image decoding. Regenerate the committed icon with:

    python3 scripts/make-ico.py windows/res/boo.ico \
        assets/icon_16x16.png assets/icon_32x32.png \
        assets/icon_128x128.png assets/icon_256x256.png
"""

import struct
import sys
from pathlib import Path


def png_size(data: bytes) -> tuple[int, int]:
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("not a PNG file")
    width, height = struct.unpack(">II", data[16:24])
    return width, height


def main() -> int:
    if len(sys.argv) < 3:
        print(__doc__, file=sys.stderr)
        return 2

    out = Path(sys.argv[1])
    pngs = [Path(p).read_bytes() for p in sys.argv[2:]]

    header = struct.pack("<HHH", 0, 1, len(pngs))
    entries = b""
    offset = len(header) + 16 * len(pngs)
    for data in pngs:
        width, height = png_size(data)
        if width > 256 or height > 256:
            raise ValueError(f"{width}x{height} exceeds the ICO limit of 256")
        entries += struct.pack(
            "<BBBBHHII",
            width % 256,  # 256 is encoded as 0
            height % 256,
            0,  # palette colors: none
            0,  # reserved
            1,  # color planes
            32,  # bits per pixel
            len(data),
            offset,
        )
        offset += len(data)

    out.write_bytes(header + entries + b"".join(pngs))
    print(f"{out}: {len(pngs)} images, {offset} bytes")
    return 0


if __name__ == "__main__":
    sys.exit(main())
