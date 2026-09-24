#!/usr/bin/env python3
"""
Build an LPAK archive (the game filesystem lovepsp mounts from DATA.PSAR).

    mkpak.py OUT.pak ROOT_DIR

Layout (little endian):
    "LPAK" u32 version=1 u32 count u32 names_size
    count * { u32 name_off, u32 data_off, u32 size, u32 flags(1=dir) }
    names blob (NUL terminated, sorted by byte order)
    file data (4-byte aligned)
data_off is relative to the start of the archive.
"""
import os
import struct
import sys


def main():
    out, root = sys.argv[1], sys.argv[2]
    entries = {}
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames.sort()
        rel = os.path.relpath(dirpath, root).replace(os.sep, "/")
        if rel != ".":
            entries[rel] = None
        for fn in sorted(filenames):
            full = os.path.join(dirpath, fn)
            name = fn if rel == "." else rel + "/" + fn
            entries[name] = full
    names = sorted(entries.keys(), key=lambda s: s.encode("utf-8"))
    blob = bytearray()
    name_offs = []
    for n in names:
        name_offs.append(len(blob))
        blob += n.encode("utf-8") + b"\0"
    header_size = 16 + 16 * len(names) + len(blob)
    data_start = (header_size + 3) & ~3
    table = bytearray()
    payload = bytearray()
    for n, noff in zip(names, name_offs):
        path = entries[n]
        if path is None:
            table += struct.pack("<IIII", noff, 0, 0, 1)
            continue
        data = open(path, "rb").read()
        off = data_start + len(payload)
        table += struct.pack("<IIII", noff, off, len(data), 0)
        payload += data
        payload += b"\0" * ((-len(payload)) % 4)
    with open(out, "wb") as f:
        f.write(b"LPAK" + struct.pack("<III", 1, len(names), len(blob)))
        f.write(table)
        f.write(blob)
        f.write(b"\0" * (data_start - header_size))
        f.write(payload)
    files = sum(1 for n in names if entries[n] is not None)
    print("mkpak: %d files, %d dirs, %.1f MiB -> %s"
          % (files, len(names) - files, (data_start + len(payload)) / 1048576.0, out))


if __name__ == "__main__":
    main()
