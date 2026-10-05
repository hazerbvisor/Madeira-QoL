#include "RuntimeLoader.h"
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>

enum MadeiraRuntime madeira_runtime_choice(const char *saved) {
    return saved && strcmp(saved, "qol") == 0 ? MadeiraRuntimeQoL : MadeiraRuntimeOriginal;
}

const char *madeira_runtime_name(enum MadeiraRuntime runtime) {
    return runtime == MadeiraRuntimeQoL ? "qol" : "original";
}

const char *madeira_runtime_library(enum MadeiraRuntime runtime) {
    return runtime == MadeiraRuntimeQoL ? "MadeiraQoL.dylib" : "Madeira.debug.dylib";
}

MadeiraRuntimeMain madeira_runtime_load(const char *path, void **handle,
                                       char *error, unsigned error_size) {
    *handle = NULL;
    /* Wine looks up some builtins through RTLD_DEFAULT. Only the selected
     * runtime may publish these symbols; the launcher contains none of them. */
    int flags = RTLD_NOW | RTLD_GLOBAL;
#ifdef __APPLE__
    flags |= RTLD_FIRST;
#endif
    void *loaded = dlopen(path, flags);
    if (!loaded) {
        snprintf(error, error_size, "%s", dlerror());
        return NULL;
    }
    dlerror();
    MadeiraRuntimeMain entry = (MadeiraRuntimeMain)dlsym(loaded, "main");
    const char *detail = dlerror();
    if (detail || !entry) {
        snprintf(error, error_size, "%s", detail ? detail : "Runtime has no main entry point");
        /* Do not load another runtime into a process that already registered
         * this runtime's Objective-C/Swift classes, even on entry-point failure. */
        return NULL;
    }
    *handle = loaded; /* Retain this image for the entire process lifetime. */
    return entry;
}
