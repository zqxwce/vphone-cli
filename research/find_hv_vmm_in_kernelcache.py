#!/usr/bin/env python3
"""find_hv_vmm_in_kernelcache.py

Investigation helper: for the given iOS kernelcache (IM4P-wrapped MH_FILESET
Mach-O), enumerate every NUL-delimited cstring `\\0kern.hv_vmm_present\\0` and
report which fileset entry (kernel or kext) and which section contains it.

Usage:
    python3 find_hv_vmm_in_kernelcache.py /path/to/kernelcache.research.vphone600

Pure-stdlib (struct only). No external deps.

Bug-fix note (v2): LC_FILESET_ENTRY.fileoff and LC_SEGMENT_64.fileoff are
relative to the bare Mach-O image. On an IM4P-wrapped kernelcache the bare
image starts at some offset `inner_off` (typically 0x37). All LC-reported
fileoffs must therefore be added to `inner_off` to get a blob offset that
can be indexed into the raw file contents. The previous version of this
script used LC fileoffs as blob offsets directly, which produced
"bad inner Mach-O magic" errors at the first sub-Mach-O lookup.
"""

from __future__ import annotations

import struct
import sys
from dataclasses import dataclass

# Mach-O constants
MH_MAGIC_64 = 0xFEEDFACF
MH_FILESET = 0xC
LC_SEGMENT_64 = 0x19
LC_FILESET_ENTRY = 0x80000035

NEEDLE = bytes([
    0x00,
    0x6B, 0x65, 0x72, 0x6E, 0x2E,                    # "kern."
    0x68, 0x76, 0x5F, 0x76, 0x6D, 0x6D, 0x5F,        # "hv_vmm_"
    0x70, 0x72, 0x65, 0x73, 0x65, 0x6E, 0x74,        # "present"
    0x00,
])


@dataclass
class FilesetEntry:
    # All offsets here are BLOB-ABSOLUTE (already adjusted by inner_off).
    vmaddr: int
    fileoff_blob: int          # absolute blob offset of the sub-Mach-O header
    fileoff_in_macho: int      # original LC-reported value (for diagnostics)
    entry_id: str
    next_fileoff_blob: int = 0


@dataclass
class Section:
    segname: str
    sectname: str
    fileoff_blob: int          # absolute blob offset
    size: int


def find_inner_macho_start(blob: bytes) -> int:
    target = struct.pack("<I", MH_MAGIC_64)
    off = blob.find(target)
    if off < 0:
        raise SystemExit("inner Mach-O magic not found")
    return off


def iter_load_commands(blob: bytes, header_off: int):
    magic, _cpu, _sub, _ftype, ncmds, sizeofcmds, _flags, _res = struct.unpack_from(
        "<IIIIIIII", blob, header_off
    )
    if magic != MH_MAGIC_64:
        raise SystemExit(
            f"bad inner Mach-O magic at blob offset {header_off:#x}: {magic:#x}")
    cur = header_off + 32
    end = cur + sizeofcmds
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", blob, cur)
        yield cmd, cmdsize, cur
        cur += cmdsize
        if cur > end:
            break


def collect_fileset_entries(
    blob: bytes, header_off: int, inner_off: int
) -> list[FilesetEntry]:
    entries: list[FilesetEntry] = []
    for cmd, cmdsize, body_off in iter_load_commands(blob, header_off):
        if cmd != LC_FILESET_ENTRY:
            continue
        vmaddr = struct.unpack_from("<Q", blob, body_off + 8)[0]
        fileoff = struct.unpack_from("<Q", blob, body_off + 16)[0]
        entry_id_off = struct.unpack_from("<I", blob, body_off + 24)[0]
        str_start = body_off + entry_id_off
        nul = blob.find(b"\x00", str_start, body_off + cmdsize)
        if nul < 0:
            nul = body_off + cmdsize
        name = blob[str_start:nul].decode("utf-8", errors="replace")
        entries.append(FilesetEntry(
            vmaddr=vmaddr,
            fileoff_blob=inner_off + fileoff,
            fileoff_in_macho=fileoff,
            entry_id=name,
        ))
    return entries


def collect_sections(
    blob: bytes, header_off_blob: int, inner_off: int
) -> list[Section]:
    """Walk LC_SEGMENT_64 commands of the sub-Mach-O at header_off_blob
    (which is already a blob-absolute offset). Each section's fileoff
    is LC-reported (Mach-O-relative); we convert to blob-absolute by
    adding inner_off.
    """
    sects: list[Section] = []
    for cmd, _cmdsize, body_off in iter_load_commands(blob, header_off_blob):
        if cmd != LC_SEGMENT_64:
            continue
        segname = blob[body_off + 8:body_off + 24].split(b"\x00", 1)[0].decode(
            "ascii", errors="replace")
        nsects = struct.unpack_from("<I", blob, body_off + 64)[0]
        for i in range(nsects):
            soff = body_off + 72 + i * 80
            sectname = blob[soff:soff + 16].split(b"\x00", 1)[0].decode(
                "ascii", errors="replace")
            seg2 = blob[soff + 16:soff + 32].split(b"\x00", 1)[0].decode(
                "ascii", errors="replace")
            size = struct.unpack_from("<Q", blob, soff + 40)[0]
            file_off = struct.unpack_from("<I", blob, soff + 48)[0]
            sects.append(Section(
                segname=seg2 or segname,
                sectname=sectname,
                fileoff_blob=inner_off + file_off,
                size=size,
            ))
    return sects


def find_all(blob: bytes, needle: bytes) -> list[int]:
    out = []
    start = 0
    while True:
        i = blob.find(needle, start)
        if i < 0:
            break
        out.append(i)
        start = i + 1
    return out


def main():
    if len(sys.argv) != 2:
        sys.exit(f"usage: {sys.argv[0]} <kernelcache.research.vphone600>")
    with open(sys.argv[1], "rb") as f:
        blob = f.read()

    inner_off = find_inner_macho_start(blob)
    print(f"# inner Mach-O magic at outer blob offset 0x{inner_off:X}")

    entries = collect_fileset_entries(blob, inner_off, inner_off)
    entries.sort(key=lambda e: e.fileoff_blob)
    for i in range(len(entries) - 1):
        entries[i].next_fileoff_blob = entries[i + 1].fileoff_blob
    entries[-1].next_fileoff_blob = len(blob)
    print(f"# {len(entries)} LC_FILESET_ENTRY commands")

    matches = find_all(blob, NEEDLE)
    print(f"# {len(matches)} NUL-delimited needle matches\n")

    print(f"{'cstring (blob)':<16} "
          f"{'fileset entry id':<55} "
          f"{'inner range (blob)':<32} "
          f"{'section':<28}")
    print("-" * 140)
    for m in matches:
        cstr_off_blob = m + 1
        owner = None
        for e in entries:
            if e.fileoff_blob <= cstr_off_blob < e.next_fileoff_blob:
                owner = e
                break
        if owner is None:
            print(f"0x{cstr_off_blob:010X}   <no fileset entry contains this offset>")
            continue

        # Walk the sub-Mach-O's sections to find which one contains the cstring.
        try:
            sects = collect_sections(blob, owner.fileoff_blob, inner_off)
        except SystemExit as e:
            print(f"0x{cstr_off_blob:010X}   {owner.entry_id:<55} "
                  f"<sub-Mach-O parse failed: {e}>")
            continue

        sect_label = "<unknown>"
        for s in sects:
            if s.fileoff_blob <= cstr_off_blob < s.fileoff_blob + s.size:
                sect_label = f"{s.segname},{s.sectname}"
                break

        print(f"0x{cstr_off_blob:010X}   "
              f"{owner.entry_id:<55} "
              f"0x{owner.fileoff_blob:010X}-0x{owner.next_fileoff_blob:010X}  "
              f"{sect_label}")


if __name__ == "__main__":
    main()
