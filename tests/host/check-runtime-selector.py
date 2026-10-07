#!/usr/bin/env python3
"""Load the production selector against competing runtime fixtures.

This checks process isolation and failed-load behavior, not Apple's dyld/UI.
"""
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
sources = root / "app/RuntimeLauncher"
fixture = r'''
#include <stdio.h>
#include <stdlib.h>
__attribute__((constructor)) static void loaded(void) {
    FILE *file = fopen(getenv("RUNTIME_TRACE"), "a");
    fputs(RUNTIME_NAME "\n", file); fclose(file);
}
int wine_process_is_running(void) { return RUNTIME_VALUE; }
#ifndef MISSING_ENTRY
int main(int argc, char **argv) { return argc == 3 && argv[2][0] == 'x' ? RUNTIME_VALUE : 99; }
#endif
'''
harness = r'''
#include "RuntimeLoader.h"
#include <assert.h>
#include <dlfcn.h>
#include <stdlib.h>
#include <string.h>
int main(int argc, char **argv) {
    assert(madeira_runtime_choice(NULL) == MadeiraRuntimeOriginal);
    assert(madeira_runtime_choice("") == MadeiraRuntimeOriginal);
    assert(madeira_runtime_choice("invalid") == MadeiraRuntimeOriginal);
    assert(madeira_runtime_choice("QOL") == MadeiraRuntimeOriginal);
    enum MadeiraRuntime selected = madeira_runtime_choice(argv[1]);
    assert(!strcmp(madeira_runtime_name(selected), argv[1]));
    assert(!strcmp(madeira_runtime_library(selected), selected == MadeiraRuntimeQoL ? "MadeiraQoL.dylib" : "Madeira.debug.dylib"));
    void *handle = NULL; char error[128] = {0};
    MadeiraRuntimeMain entry = madeira_runtime_load(argv[2], &handle, error, sizeof(error));
    if (argc > 3) {
        assert(!entry && !handle && error[0]);
        return 0;
    }
    int expected = selected == MadeiraRuntimeQoL ? 22 : 11;
    assert(entry && handle && !error[0]);
    char *arguments[] = {"Madeira", "arg", "x", NULL};
    assert(entry(3, arguments) == expected);
    // Wine's RTLD_DEFAULT lookup sees the selected runtime's symbols.
    int (*running)(void) = dlsym(RTLD_DEFAULT, "wine_process_is_running");
    assert(running && running() == expected);
    return 0;
}
'''
with tempfile.TemporaryDirectory(prefix="madeira-runtime-") as temporary:
    directory = Path(temporary)
    (directory / "fixture.c").write_text(fixture)
    (directory / "harness.c").write_text(harness)
    cc = os.environ.get("HOST_CC", "cc")
    for name, value, missing in [("original", 11, False), ("qol", 22, False), ("broken", 33, True)]:
        command = [cc, "-shared", "-fPIC", str(directory / "fixture.c"),
                   '-DRUNTIME_NAME="' + name + '"', "-DRUNTIME_VALUE=" + str(value),
                   "-o", str(directory / (name + ".so"))]
        if missing:
            command.append("-DMISSING_ENTRY")
        subprocess.run(command, check=True)
    subprocess.run([cc, "-Wall", "-Wextra", "-Werror", "-I", str(sources),
                    str(directory / "harness.c"), str(sources / "RuntimeLoader.c"),
                    "-ldl", "-o", str(directory / "test")], check=True)
    trace = directory / "trace"
    environment = dict(os.environ, RUNTIME_TRACE=str(trace))
    for choice in ("original", "qol"):
        trace.unlink(missing_ok=True)
        subprocess.run([str(directory / "test"), choice, str(directory / (choice + ".so"))], env=environment, check=True)
        assert trace.read_text() == choice + "\n", "More than one runtime initialized"
    trace.unlink()
    subprocess.run([str(directory / "test"), "original", str(directory / "missing.so"), "expect-failure"], env=environment, check=True)
    assert not trace.exists(), "Missing runtime silently loaded a replacement"
    subprocess.run([str(directory / "test"), "qol", str(directory / "broken.so"), "expect-failure"], env=environment, check=True)
    assert trace.read_text() == "broken\n", "Entry failure initialized another runtime"
print("PASS: default original, explicit QoL, one runtime per process, Wine global lookup, no fallback on load/entry failure")
