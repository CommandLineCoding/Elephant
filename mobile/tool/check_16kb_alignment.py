#!/usr/bin/env python3
"""Check that an APK's 64-bit native libraries can load on 16 KB-page devices.

Some Android devices use 16 KB memory pages, and can only load a native
library whose ELF LOAD segments are aligned to at least 16 KB. 32-bit ABIs
never use 16 KB pages, so only arm64-v8a and x86_64 are checked.

Usage: check_16kb_alignment.py APK [APK ...]
Exits 1 and names the libraries if any are aligned to less than 16 KB.
"""

import struct
import sys
import zipfile

PAGE = 16 * 1024
PT_LOAD = 1
ABIS = ("lib/arm64-v8a/", "lib/x86_64/")


def load_alignments(elf: bytes) -> set[int]:
    """The p_align of every PT_LOAD segment of a 64-bit little-endian ELF."""
    phoff = struct.unpack_from("<Q", elf, 0x20)[0]
    phentsize, phnum = struct.unpack_from("<HH", elf, 0x36)
    aligns = set()
    for i in range(phnum):
        entry = phoff + i * phentsize
        if struct.unpack_from("<I", elf, entry)[0] == PT_LOAD:
            aligns.add(struct.unpack_from("<Q", elf, entry + 0x30)[0])
    return aligns


def check(apk: str) -> list[str]:
    bad = []
    with zipfile.ZipFile(apk) as z:
        for name in z.namelist():
            if not (name.startswith(ABIS) and name.endswith(".so")):
                continue
            aligns = load_alignments(z.read(name))
            if not aligns or min(aligns) < PAGE:
                shown = ", ".join(hex(a) for a in sorted(aligns))
                bad.append(f"{apk}: {name} (LOAD alignment {shown})")
    return bad


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    bad = [line for apk in sys.argv[1:] for line in check(apk)]
    for line in bad:
        print(f"not 16 KB aligned: {line}", file=sys.stderr)
    if not bad:
        print(f"All 64-bit native libraries are 16 KB aligned ({len(sys.argv) - 1} APKs).")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
