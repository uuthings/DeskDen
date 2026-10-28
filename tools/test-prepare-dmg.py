#!/usr/bin/env python3
"""Focused safety checks; never build, sign, mount or submit anything."""
from pathlib import Path
import plistlib
import runpy
import subprocess
import tempfile
import unittest


PREPARE = runpy.run_path(str(Path(__file__).with_name('prepare-dmg.py')))


class PreparationChecks(unittest.TestCase):
    def test_existing_output_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(ValueError, 'never overwritten'):
                PREPARE['validate_output'](Path(directory), Path('/release-original'))

    def test_original_archive_and_repository_are_rejected(self):
        for output, release in [(Path('/release-original/new'), Path('/release-original')),
                                (PREPARE['ROOT'] / 'new-dmg', Path('/release-original'))]:
            with self.assertRaisesRegex(ValueError, 'outside'):
                PREPARE['validate_output'](output, release)

    def test_cache_and_temporary_output_are_rejected(self):
        for path in ['/tmp/fangcun-new-dmg', '/persistent/DerivedData/new-dmg']:
            with self.assertRaises(ValueError):
                PREPARE['validate_output'](Path(path), Path('/release-original'))

    def test_manifest_detects_content_mode_and_link_changes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            file = root / 'binary'
            file.write_bytes(b'original')
            (root / 'relative').symlink_to('binary')
            original = PREPARE['manifest'](root)
            file.write_bytes(b'changed')
            self.assertNotEqual(original, PREPARE['manifest'](root))
            file.write_bytes(b'original')
            file.chmod(0o700)
            self.assertNotEqual(original, PREPARE['manifest'](root))
            (root / 'relative').unlink()
            (root / 'relative').symlink_to('/Applications')
            with self.assertRaisesRegex(ValueError, 'external symbolic link'):
                PREPARE['manifest'](root)

    def test_no_ad_hoc_identity(self):
        with self.assertRaisesRegex(ValueError, 'existing Developer ID'):
            PREPARE['prepare'](Path('/absent-release'), Path('/new-output'), '-')

    def test_apple_submission_id_is_case_insensitive_but_must_match(self):
        identifier = 'A1234567-1234-5678-9ABC-123456789ABC'
        log = {'jobId': identifier.lower(), 'status': 'Accepted', 'statusCode': 0}
        self.assertTrue(PREPARE['accepted_submission'](log, identifier))
        self.assertFalse(PREPARE['accepted_submission'](log, 'B1234567-1234-5678-9ABC-123456789ABC'))
        self.assertFalse(PREPARE['accepted_submission']({**log, 'status': 'Invalid'}, identifier))

    def test_attach_failure_still_detaches_actual_volume(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            dmg = output / 'candidate.dmg'
            attached = True
            commands = []

            def runner(command, **kwargs):
                nonlocal attached
                commands.append(command)
                if command[:2] == ['hdiutil', 'detach']:
                    attached = False
                    return subprocess.CompletedProcess(command, 0, b'', b'')
                images = [{'image-path': str(dmg), 'system-entities': [{'mount-point': str(workspace / 'Mounted')}]}] if attached else []
                return subprocess.CompletedProcess(command, 0, plistlib.dumps({'images': images}), b'')

            with self.assertRaisesRegex(RuntimeError, 'attach reported failure'):
                with PREPARE['packaging_workspace'](output, dmg, runner) as workspace:
                    (workspace / 'Mounted').mkdir()
                    raise RuntimeError('attach reported failure after mounting')
            self.assertFalse(attached)
            self.assertFalse(workspace.exists())
            self.assertEqual(sum(c[:2] == ['hdiutil', 'detach'] for c in commands), 1)

    def test_detach_failure_preserves_workspace(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            dmg = output / 'candidate.dmg'

            def runner(command, **kwargs):
                if command[:2] == ['hdiutil', 'detach']:
                    return subprocess.CompletedProcess(command, 1, b'', b'volume busy')
                images = [{'image-path': str(dmg), 'system-entities': [{'mount-point': str(workspace / 'Mounted')}]}]
                return subprocess.CompletedProcess(command, 0, plistlib.dumps({'images': images}), b'')

            with self.assertRaisesRegex(RuntimeError, 'retained'):
                with PREPARE['packaging_workspace'](output, dmg, runner) as workspace:
                    (workspace / 'Mounted').mkdir()
                    (workspace / 'evidence').write_text('must remain')
            self.assertEqual((workspace / 'evidence').read_text(), 'must remain')


if __name__ == '__main__':
    unittest.main()
