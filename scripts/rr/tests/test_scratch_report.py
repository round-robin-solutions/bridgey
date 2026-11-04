"""Only isolated metadata fixtures; no player, device, cache, or app invocation."""
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location('scratch_report', Path(__file__).parents[1] / 'scratch-report.py')
probe = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(probe)


class ScratchReportTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name).resolve()
        for name in ('repo', 'home', 'tmp'):
            (self.root / name).mkdir()

    def tearDown(self):
        self.tmp.cleanup()

    def test_sparse_hardlink_and_no_contents_or_symlink_escape(self):
        sparse = self.root / 'repo/sparse'
        with sparse.open('wb') as stream:
            stream.truncate(64 * 1024**2)
        os.link(sparse, self.root / 'tmp/linked')
        secret = self.root / 'private'
        secret.write_text('NEVER_LEAK_CONTENT_OR_SYMLINK_TARGET')
        (self.root / 'repo/escape').symlink_to(secret)
        (self.root / 'tmp/escape-dir').symlink_to(self.root, target_is_directory=True)
        result = probe.collect(self.root)
        total = result['totals']
        self.assertEqual(total['logical_bytes'], 128 * 1024**2 + secret.stat().st_size)
        self.assertEqual(total['unique_logical_bytes'], 64 * 1024**2 + secret.stat().st_size)
        self.assertLess(total['allocated_bytes'], total['logical_bytes'])
        self.assertEqual(result['skipped']['symlink'], 2)
        self.assertFalse(result['partial'])
        row = next(r for r in result['top_files'] if r['path'] == 'repo/sparse')
        self.assertEqual(row['nlink'], 2)
        self.assertEqual((row['dev'], row['inode']), (sparse.stat().st_dev, sparse.stat().st_ino))
        self.assertNotIn('NEVER_LEAK', probe.encode(result))
        self.assertFalse(any('escape' in r['path'] for r in result['top_files']))

    def test_symlink_directory_and_root_are_never_followed(self):
        outside = self.root / 'unregistered'
        outside.mkdir()
        (outside / 'secret').write_bytes(b'outside')
        (self.root / 'repo/link').symlink_to(outside, target_is_directory=True)
        result = probe.collect(self.root)
        self.assertEqual(result['totals']['files'], 0)
        self.assertIn('unregistered-directory', result['reasons'])
        self.assertEqual(probe.collect(self.root / 'repo/link')['totals']['files'], 0)
        self.assertTrue(probe.collect(self.root / 'repo/link')['partial'])

    def test_entry_depth_and_time_limits(self):
        for index in range(30):
            (self.root / 'repo' / str(index)).touch()
        result = probe.collect(self.root, entries=4)
        self.assertEqual(result['visited_entries'], 4)
        self.assertIn('entry-limit', result['reasons'])
        nested = self.root / 'home/deeper'
        nested.mkdir()
        (nested / 'file').touch()
        self.assertIn('depth-limit', probe.collect(self.root, depth=1)['reasons'])
        ticks = iter([0, 1, 1, 1, 1])
        timed = probe.collect(self.root, seconds=.5, clock=lambda: next(ticks))
        self.assertIn('deadline', timed['reasons'])
        self.assertEqual(timed['totals']['files'], 0)

    def test_clipped_escaped_paths_top_count_and_output_cap(self):
        parent = self.root / 'repo' / ('x' * 145)
        parent.mkdir()
        for index in range(50):
            (parent / ('newline\n\t"' + str(index))).write_bytes(b'x' * index)
        result = probe.collect(self.root)
        encoded = probe.encode(result)
        self.assertLessEqual(len(result['top_files']), 32)
        self.assertTrue(all(r['path_clipped'] for r in result['top_files']))
        self.assertLessEqual(len(encoded.encode('ascii')), probe.MAX_OUTPUT)
        self.assertEqual(encoded.count('\n'), 1)
        self.assertIn('\\n', encoded)
        self.assertEqual(json.loads(encoded[len(probe.PREFIX):]), result)
        with patch.object(probe, 'MAX_OUTPUT', 1500):
            clipped = probe.encode(result)
        self.assertLessEqual(len(clipped.encode('ascii')), 1500)
        self.assertIn('output-limit', json.loads(clipped[len(probe.PREFIX):])['reasons'])

    def test_ownership_rejects_arbitrary_tmpdir_and_error_text_is_absent(self):
        with patch.dict(os.environ, {'RR_CI_OUTPUT': str(self.root), 'TMPDIR': '/tmp',
                                     'RR_CI_ATTEMPT': 'a' * 32}):
            with self.assertRaises(ValueError):
                probe.owned_root()
        with patch.object(probe.os, 'scandir', side_effect=PermissionError('SECRET_ERROR')):
            result = probe.collect(self.root)
        self.assertTrue(result['partial'])
        self.assertNotIn('SECRET_ERROR', probe.encode(result))
        self.assertGreater(result['skipped']['errors'], 0)


if __name__ == '__main__':
    unittest.main()
