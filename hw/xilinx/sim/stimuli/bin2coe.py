#!/usr/bin/env python3
"""bin2coe.py — convert a flat little-endian binary into a Xilinx .coe
(32-bit words, hex radix), matching the format of initRV32.coe so the real
xlnx_blk_mem_gen_0 sim-model preloads it. Word N == byte offset 4*N.

Usage: bin2coe.py <in.bin> <out.coe> [--word-bytes 4]
"""
import sys, argparse

def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("inp"); ap.add_argument("outp")
    ap.add_argument("--word-bytes", type=int, default=4)
    a = ap.parse_args()
    data = open(a.inp, "rb").read()
    wb = a.word_bytes
    if len(data) % wb:
        data += b"\x00" * (wb - len(data) % wb)          # pad up to a full word
    words = [int.from_bytes(data[i:i+wb], "little") for i in range(0, len(data), wb)]
    with open(a.outp, "w") as f:
        f.write("memory_initialization_radix = 16;\n")
        f.write("memory_initialization_vector =\n")
        f.write(",\n".join(f"{w:0{wb*2}x}" for w in words))
        f.write(";\n")
    print(f"[bin2coe] {a.inp}: {len(data)} bytes -> {len(words)} words -> {a.outp}")
    return 0

if __name__ == "__main__":
    sys.exit(main())
