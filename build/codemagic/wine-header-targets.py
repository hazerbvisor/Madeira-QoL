#!/usr/bin/env python3
"""Find the WIDL headers needed by Madeira's native Wine translation units."""
import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parents[2]
WINE = ROOT / 'wine'
NATIVE_DIRS = ('ntdll-unix', 'wineserver', 'win32u-unix', 'crypto-unix')
WINE_DIRS = ('server', 'dlls/ntdll', 'dlls/ntdll/unix', 'dlls/win32u',
             'dlls/dwrite', 'dlls/winegstreamer', 'dlls/ws2_32', 'dlls/bcrypt',
             'dlls/secur32', 'dlls/crypt32', 'dlls/nsiproxy.sys', 'dlls/dnsapi')
SEARCH = [WINE / 'include'] + [WINE / d for d in WINE_DIRS] + [ROOT / 'build' / d for d in NATIVE_DIRS]
# Include native overrides and the upstream .c files they wrap. Walking quoted
# includes resolves freetype.c/unixlib.h from the original DLL source directory.
pending = [p for d in NATIVE_DIRS for p in (ROOT / 'build' / d).glob('*.c')]
pending += [p for d in ('server', 'dlls/ntdll/unix', 'dlls/win32u') for p in (WINE / d).glob('*.c')]
pending += [WINE / p for p in ('dlls/dwrite/freetype.c', 'dlls/ws2_32/unixlib.c',
                              'dlls/bcrypt/gnutls.c', 'dlls/secur32/schannel_gnutls.c',
                              'dlls/winegstreamer/unixlib.h')]
visited, targets = set(), set()
while pending:
    path = pending.pop()
    if path in visited:
        continue
    visited.add(path)
    text = path.read_text().replace(r'\"', '"')
    includes = re.findall(r'^\s*#\s*include\s*[<"]([^>"\n]+)', text, re.M)
    includes += re.findall(r'cpp_quote\("#\s*include\s*[<"]([^>"\n]+)', text)
    # WIDL imports reference another generated header. An IDL preprocessor
    # #include instead inlines declarations and has no independent .h target.
    references = [(name, False) for name in includes]
    references += [(name, True) for name in re.findall(r'\bimport\s+"([^"\n]+\.idl)"', text)]
    for name, imported in references:
        for directory in [path.parent] + SEARCH:
            candidate = directory / name
            if candidate.is_file():
                candidate = candidate.resolve()
                pending.append(candidate)
                if imported and candidate.suffix == '.idl' and candidate.parent == WINE / 'include':
                    targets.add('include/' + candidate.stem + '.h')
                break
        else:
            if name.endswith('.h'):
                idl = WINE / 'include' / (name[:-2] + '.idl')
                if idl.is_file():
                    targets.add('include/' + name)
                    pending.append(idl)
for target in sorted(targets):
    print(target)
