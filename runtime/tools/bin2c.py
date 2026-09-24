#!/usr/bin/env python3
"""Embed a file as a C array: bin2c.py input output.h symbol"""
import sys

src, dst, sym = sys.argv[1], sys.argv[2], sys.argv[3]
data = open(src, "rb").read()
with open(dst, "w") as f:
    f.write("/* generated from %s -- do not edit */\n" % src)
    f.write("static const char %s[] = {\n" % sym)
    for i in range(0, len(data), 16):
        f.write("  " + ", ".join("%d" % (b if b < 128 else b - 256) for b in data[i:i + 16]) + ",\n")
    f.write("  0\n};\n")
    f.write("static const unsigned int %s_len = %d;\n" % (sym, len(data)))
