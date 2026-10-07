#!/usr/bin/env python3
"""Exercise Wine's actual fault-emulation helpers with Darwin's register layout.

The signal handler cannot run on this host. Extract its C helpers and run the
FP/LR/SP and zero-register cases with optimized code and bounds sanitizers.
--source can point at an older signal_arm64_ios.c to reproduce its bounds bug.
"""
import argparse
import os
from pathlib import Path
import re
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--source", type=Path, default=root / "build/ntdll-unix/signal_arm64_ios.c")
args = parser.parse_args()
source = args.source.read_text()


def function(name):
    definition = re.search(r"^static[^\n]*\b" + name + r"\([^;\n]*\)\n\{", source, re.M)
    assert definition, name
    start, opening = definition.start(), definition.end() - 1
    depth, end = 1, opening + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


darwin = source[source.index("#elif defined(__APPLE__)"):]
register_macro = re.search(r"^# define REGn_sig[^\n]+", darwin, re.M).group()
store_macro = re.search(r"^#define IOS_STORE_SRC[^\n]+", source, re.M).group()
harness = r"""
#include <assert.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>
typedef uint64_t __uint64_t;
#define _STRUCT_ARM_THREAD_STATE64 struct arm_state
_STRUCT_ARM_THREAD_STATE64 {
    __uint64_t __x[29], __fp, __lr, __sp, __pc;
    uint32_t __cpsr;
};
struct machine_context {
    struct arm_state __ss;
    struct { unsigned __int128 __v[32]; } __ns;
};
typedef struct { struct machine_context *uc_mcontext; } ucontext_t;
static int ios_neon_valid;
#include "ios_arm64_registers.h"
""" + register_macro + "\n" + store_macro + "\n"
harness += function("ios_get_reg") + "\n"
harness += function("ios_emulate_unaligned_guest_access") + "\n"
harness += r"""
int main(void)
{
    struct machine_context machine = {0};
    ucontext_t context = { &machine };
    struct arm_state state = {0};
    uint64_t memory[2];
    for (unsigned r = 0; r < 29; r++) state.__x[r] = 0x100000000ULL + r;
    state.__fp = 0x702680f400ULL;
    state.__lr = 0x71fce2aa8bULL;
    state.__sp = 0x702680f2e0ULL;
    machine.__ss = state;
    for (unsigned r = 0; r <= 30; r++) {
        uint64_t expected = r < 29 ? 0x100000000ULL + r :
                            r == 29 ? state.__fp : state.__lr;
        assert(ios_get_reg(&context, r) == expected);
        assert(IOS_STORE_SRC(r) == expected);
    }
    assert(ios_get_reg(&context, 31) == 0);
    assert(IOS_STORE_SRC(31) == 0);
    assert(IOS_ARM64_REG(state, 31) == state.__sp);
    IOS_ARM64_REG(state, 31) += 8;
    assert(state.__sp == 0x702680f2e8ULL);
    assert(ios_arm64_register_slot(&state, 32) == NULL);

    /* STR/LDR LR: round-trip a real high-address return value. */
    memory[0] = 0;
    assert(ios_emulate_unaligned_guest_access(&context, 0xf900001e, (uintptr_t)memory));
    assert(memory[0] == machine.__ss.__lr);
    machine.__ss.__lr = 1;
    assert(ios_emulate_unaligned_guest_access(&context, 0xf940001e, (uintptr_t)memory));
    assert(machine.__ss.__lr == 0x71fce2aa8bULL);

    /* STP/LDP FP,LR: neither register is in __x. */
    assert(ios_emulate_unaligned_guest_access(&context, 0xa900781d, (uintptr_t)memory));
    assert(memory[0] == machine.__ss.__fp && memory[1] == machine.__ss.__lr);
    machine.__ss.__fp = 2;
    machine.__ss.__lr = 1;
    assert(ios_emulate_unaligned_guest_access(&context, 0xa940781d, (uintptr_t)memory));
    assert(machine.__ss.__fp == 0x702680f400ULL && machine.__ss.__lr == 0x71fce2aa8bULL);

    /* W29 loads zero-extend FP; XZR stores zero and loads discard. */
    memory[0] = 0xffffffff12345678ULL;
    assert(ios_emulate_unaligned_guest_access(&context, 0xb940001d, (uintptr_t)memory));
    assert(machine.__ss.__fp == 0x12345678);
    assert(ios_emulate_unaligned_guest_access(&context, 0xf900001f, (uintptr_t)memory));
    assert(memory[0] == 0);
    memory[0] = UINT64_MAX;
    assert(ios_emulate_unaligned_guest_access(&context, 0xf940001f, (uintptr_t)memory));
    assert(machine.__ss.__sp == 0x702680f2e0ULL);
    return 0;
}
"""
with tempfile.TemporaryDirectory() as directory:
    c = Path(directory) / "registers.c"
    c.write_text(harness)
    executable = c.with_suffix("")
    subprocess.run([os.environ.get("CC", "cc"), "-std=gnu11", "-O2", "-Wall", "-Wextra",
                    "-Werror", "-Wno-error=array-bounds", "-fsanitize=undefined,bounds", "-fno-sanitize-recover=all",
                    "-I", str(root / "build/ntdll-unix"), str(c), "-o", str(executable)], check=True)
    subprocess.run([str(executable)], check=True)
print("PASS: optimized FP/LR/SP access, return-address loads/stores, pairs and XZR with bounds sanitizers")
