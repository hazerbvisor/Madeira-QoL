#pragma once

/* The launcher must not link either app's Swift, Wine, FEX or DXMT objects. */
typedef int (*MadeiraRuntimeMain)(int, char **);
enum MadeiraRuntime { MadeiraRuntimeOriginal, MadeiraRuntimeQoL };

enum MadeiraRuntime madeira_runtime_choice(const char *saved);
const char *madeira_runtime_name(enum MadeiraRuntime runtime);
const char *madeira_runtime_library(enum MadeiraRuntime runtime);
MadeiraRuntimeMain madeira_runtime_load(const char *path, void **handle,
                                       char *error, unsigned error_size);
