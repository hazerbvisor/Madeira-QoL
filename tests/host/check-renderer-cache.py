#!/usr/bin/env python3
"""Exercise real startup SQLite validation: valid DB retained, corrupt DB evicted."""
import os, subprocess, tempfile
from pathlib import Path
root=Path(__file__).resolve().parents[2]
source=(root/'app/Madeira/RendererCaches.swift').read_text()
a=source.index('    private static func validateShaderDatabases(')
b=source.index('    private static func prune(',a)
method=source[a:b].replace('private static func','static func')
with tempfile.TemporaryDirectory() as directory:
    work=Path(directory); module=work/'SQLite3';module.mkdir()
    header=Path(os.environ.get('SQLITE3_INCLUDE', '/usr/include/sqlite3.h'))
    if not header.exists():
        sdk=subprocess.check_output(['xcrun','--show-sdk-path'],text=True).strip()
        header=Path(sdk)/'usr/include/sqlite3.h'
    (module/'module.modulemap').write_text(f'module SQLite3 [system] {{ header "{header}"\n link "sqlite3"\n export *\n}}')
    main=work/'main.swift'
    main.write_text('import Foundation\nimport SQLite3\nenum Cache {\n'+method+'}\n'+r'''
let root = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
let valid = root.appendingPathComponent("valid.db")
var db: OpaquePointer?
assert(sqlite3_open(valid.path, &db) == SQLITE_OK)
assert(sqlite3_exec(db, "CREATE TABLE pipeline(k TEXT); INSERT INTO pipeline VALUES ('retained');", nil, nil, nil) == SQLITE_OK)
sqlite3_close(db)
let saved = try Data(contentsOf: valid)
let corrupt = root.appendingPathComponent("corrupt.db")
for suffix in ["", "-wal", "-shm", "-lock"] { try Data("bad cache".utf8).write(to: URL(fileURLWithPath: corrupt.path + suffix)) }
let unrelated = root.appendingPathComponent("game-save.bin")
try Data("untouched".utf8).write(to: unrelated)
Cache.validateShaderDatabases(in: root)
let retained = try Data(contentsOf: valid)
assert(retained == saved)
for suffix in ["", "-wal", "-shm", "-lock"] { assert(!FileManager.default.fileExists(atPath: corrupt.path + suffix)) }
assert(FileManager.default.fileExists(atPath: unrelated.path))
Cache.validateShaderDatabases(in: root) // idempotent; absent/corrupt cache is a miss
Cache.validateShaderDatabases(in: root.appendingPathComponent("absent"))
print("PASS: valid SQLite reuse, corrupt DB/journal/lock invalidation, unrelated files retained and missing-cache fallback")
''')
    flags=['-L',os.environ['SQLITE3_LIBRARY_DIR']] if 'SQLITE3_LIBRARY_DIR' in os.environ else []
    subprocess.run([os.environ.get('SWIFTC','swiftc'),'-I',str(work),*flags,str(main),'-o',str(work/'cache')],check=True)
    subprocess.run([str(work/'cache'),str(work/'cache-data')],check=True)
