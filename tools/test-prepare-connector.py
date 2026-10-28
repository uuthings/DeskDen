#!/usr/bin/env python3
"""Verify the public connector package contains only reproducible generic inputs."""
from pathlib import Path
import runpy
import tempfile
import unittest
import zipfile

PREPARE = runpy.run_path(str(Path(__file__).with_name('prepare-connector.py')))['prepare']


class ConnectorPackageTests(unittest.TestCase):
    def test_generic_reproducible_package_and_executable_installer(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            first, second = PREPARE(root / 'first'), PREPARE(root / 'second')
            self.assertEqual(first['sha256'], second['sha256'])
            with zipfile.ZipFile(root / 'first' / first['file']) as z:
                names = z.namelist()
                self.assertEqual(len(names), len(set(names)))
                self.assertTrue(all(n.startswith('DeskDen-IPRoyal-Connector/') for n in names))
                self.assertFalse(any(n.endswith(('native-host.command', '.request.json', '.result.json')) or 'Runtime/' in n for n in names))
                self.assertFalse(any('com.uuthings.' in n for n in names))
                self.assertEqual(z.getinfo('DeskDen-IPRoyal-Connector/install.command').external_attr >> 16 & 0o777, 0o755)
            with self.assertRaises(ValueError):
                PREPARE(root / 'first')


if __name__ == '__main__': unittest.main()
