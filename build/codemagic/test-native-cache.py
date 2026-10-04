#!/usr/bin/env python3
"""Exercise reuse and invalidation with a real tracked ARM64 iOS archive."""
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest

SCRIPT = Path(__file__).with_name('native-cache.py')
spec = importlib.util.spec_from_file_location('native_cache', SCRIPT)
cache = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cache)
REAL_ARCHIVE = cache.ROOT / 'app/Madeira/libgmp.a'


class NativeCacheTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name) / 'repo'
        self.root.mkdir()
        subprocess.run(['git', 'init', '-q', str(self.root)], check=True)
        (self.root / 'source.c').write_text('/* original source */\n')
        subprocess.run(['git', '-C', str(self.root), 'add', 'source.c'], check=True)
        (self.root / 'library.a').write_bytes(REAL_ARCHIVE.read_bytes())
        (self.root / 'include').mkdir()
        (self.root / 'include/generated.h').write_text('#define ABI_VERSION 1\n')
        (self.root / 'NOTICE.txt').write_text('Required license notice\n')
        self.original_root, cache.ROOT = cache.ROOT, self.root
        cache.SPECS['fixture'] = {'inputs': ['source.c'], 'outputs': ['library.a', 'include', 'NOTICE.txt'], 'clean': []}
        cache.SPECS['dependent'] = {'inputs': [], 'dependencies': ['fixture'], 'outputs': [], 'clean': []}
        self.identity = {'sdk': '26.5', 'clang': '21', 'xcode': '26.5'}
        self.key = cache.key('fixture', self.identity)
        self.archive = Path(self.temporary.name) / 'fixture.tar.gz'
        self.destination = Path(self.temporary.name) / 'restored'
        cache.save(self.archive, 'fixture', self.key)

    def tearDown(self):
        cache.ROOT = self.original_root
        cache.SPECS.pop('fixture')
        cache.SPECS.pop('dependent')
        self.temporary.cleanup()

    def mutate_bundle(self, mutation):
        with tarfile.open(self.archive) as bundle:
            payloads = {m.name: bundle.extractfile(m).read() for m in bundle.getmembers()}
        mutation(payloads)
        with tarfile.open(self.archive, 'w:gz') as bundle:
            for name, data in payloads.items():
                info = tarfile.TarInfo(name)
                info.size = len(data)
                bundle.addfile(info, io.BytesIO(data))

    def test_restores_real_ios_archive_headers_and_notices(self):
        self.assertTrue(cache.restore(self.archive, 'fixture', self.key, self.destination))
        for relative in ('library.a', 'include/generated.h', 'NOTICE.txt'):
            self.assertEqual((self.destination / relative).read_bytes(), (self.root / relative).read_bytes())

    def test_source_change_invalidates_component_and_dependent(self):
        dependent_key = cache.key('dependent', self.identity)
        (self.root / 'source.c').write_text('/* changed source */\n')
        changed = cache.key('fixture', self.identity)
        self.assertNotEqual(changed, self.key)
        self.assertNotEqual(cache.key('dependent', self.identity), dependent_key)
        with self.assertRaisesRegex(ValueError, 'identity mismatch'):
            cache.restore(self.archive, 'fixture', changed, self.destination)
        self.assertFalse(self.destination.exists())

    def test_sdk_change_rejects_old_archive(self):
        changed = cache.key('fixture', {**self.identity, 'sdk': '27.0'})
        self.assertNotEqual(changed, self.key)
        with self.assertRaisesRegex(ValueError, 'identity mismatch'):
            cache.restore(self.archive, 'fixture', changed, self.destination)
        self.assertFalse(self.destination.exists())

    def test_corrupt_header_does_not_partially_stage_libraries(self):
        self.mutate_bundle(lambda files: files.__setitem__('include/generated.h', b'corrupt'))
        with self.assertRaisesRegex(ValueError, 'checksum mismatch'):
            cache.restore(self.archive, 'fixture', self.key, self.destination)
        self.assertFalse(self.destination.exists())

    def test_cache_cannot_overwrite_source(self):
        def inject(files):
            files['source.c'] = b'unexpected overwrite'
            manifest = json.loads(files['manifest.json'])
            manifest['files']['source.c'] = cache.sha(files['source.c'])
            files['manifest.json'] = json.dumps(manifest).encode()
        self.mutate_bundle(inject)
        with self.assertRaisesRegex(ValueError, 'invalid cache path'):
            cache.restore(self.archive, 'fixture', self.key, self.destination)
        self.assertFalse(self.destination.exists())

    def test_incomplete_component_cannot_be_saved(self):
        (self.root / 'NOTICE.txt').unlink()
        with self.assertRaisesRegex(ValueError, 'missing completed component output'):
            cache.save(self.archive, 'fixture', self.key)


if __name__ == '__main__':
    unittest.main()
