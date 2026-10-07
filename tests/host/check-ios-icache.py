#!/usr/bin/env python3
"""Execute a linked iOS Wine cache-flush syscall in an ARM64 emulator.

Requires Python unicorn and llvm-objdump. This checks real machine-code routing
and exact cache-service arguments; it does not emulate hardware cache coherence.
The original release passes via __clear_cache; the old rebuilt no-op fails.
"""
import argparse
from pathlib import Path
import re
import struct
import subprocess

from unicorn import Uc, UC_ARCH_ARM64, UC_MODE_ARM, UC_HOOK_CODE
from unicorn.arm64_const import UC_ARM64_REG_X0, UC_ARM64_REG_X1, UC_ARM64_REG_X2
from unicorn.arm64_const import UC_ARM64_REG_X30, UC_ARM64_REG_SP, UC_ARM64_REG_PC

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("runtime", type=Path)
parser.add_argument("--objdump", default="llvm-objdump")
args = parser.parse_args()
data = args.runtime.read_bytes()
assert struct.unpack_from("<I", data)[0] == 0xfeedfacf
segments, symbols, log_functions = [], {}, set()
offset = 32
for _ in range(struct.unpack_from("<I", data, 16)[0]):
    command, length = struct.unpack_from("<II", data, offset)
    if command == 0x19:
        name = data[offset + 8:offset + 24].split(b"\0")[0]
        address, size, file_offset, file_size = struct.unpack_from("<4Q", data, offset + 24)
        if name != b"__PAGEZERO" and size:
            segments.append((address, size, file_offset, file_size))
    if command == 2:
        table, count, strings, _ = struct.unpack_from("<4I", data, offset + 8)
        for index in range(count):
            string, kind, _, _, value = struct.unpack_from("<IBBHQ", data, table + 16 * index)
            if kind & 0xe == 0xe and not kind & 0xe0:
                end = data.index(b"\0", strings + string)
                name = data[strings + string:end].decode()
                symbols[name] = value
                if name == "_wine_dbg_log":
                    log_functions.add(value)
    offset += length
imports = subprocess.check_output(
    [args.objdump, "--macho", "--indirect-symbols", str(args.runtime)], text=True)
services = {int(address, 16): name for address, name in
            re.findall(r"^(0x[0-9a-fA-F]+)\s+\d+\s+(\S+)\s*$", imports, re.M)}
emulator = Uc(UC_ARCH_ARM64, UC_MODE_ARM)
for address, size, file_offset, file_size in segments:
    emulator.mem_map(address, (size + 4095) & ~4095)
    emulator.mem_write(address, data[file_offset:file_offset + file_size])
scratch = 0x40000000
emulator.mem_map(scratch, 0x20000)
stop, stack = scratch + 0x1000, scratch + 0x10000
calls = []


def service(uc, address, size, user):
    name = services.get(address)
    if name is None and address in log_functions:
        name = "_wine_dbg_log"
    if name is None:
        return
    if name in ("_sys_icache_invalidate", "___clear_cache"):
        begin, length = uc.reg_read(UC_ARM64_REG_X0), uc.reg_read(UC_ARM64_REG_X1)
        if name == "___clear_cache":
            length -= begin
        calls.append((begin, length))
    elif name not in ("_dprintf", "_wine_dbg_log"):
        raise AssertionError("unexpected external call: " + name)
    uc.reg_write(UC_ARM64_REG_X0, 0)
    uc.reg_write(UC_ARM64_REG_PC, uc.reg_read(UC_ARM64_REG_X30))


emulator.hook_add(UC_HOOK_CODE, service)
for handle, address, length, expected in [
    (0xffffffffffffffff, scratch + 0x12000, 276, 1),
    (0xffffffffffffffff, scratch + 0x13000, 4, 1),
    (0x1234, scratch + 0x14000, 64, 0),
]:
    previous = len(calls)
    emulator.reg_write(UC_ARM64_REG_X0, handle)
    emulator.reg_write(UC_ARM64_REG_X1, address)
    emulator.reg_write(UC_ARM64_REG_X2, length)
    emulator.reg_write(UC_ARM64_REG_X30, stop)
    emulator.reg_write(UC_ARM64_REG_SP, stack)
    emulator.emu_start(symbols["_NtFlushInstructionCache"], stop, count=10000)
    assert emulator.reg_read(UC_ARM64_REG_PC) == stop
    assert emulator.reg_read(UC_ARM64_REG_SP) == stack
    assert emulator.reg_read(UC_ARM64_REG_X0) == 0
    assert len(calls) - previous == expected, "cache service not called as required"
    if expected:
        assert calls[-1] == (address, length), "wrong cache-flush span"
print("PASS: linked ARM64 syscall flushes exact block/patch spans; remote handles do not flush this task")
