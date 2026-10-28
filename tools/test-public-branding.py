#!/usr/bin/env python3
"""Reject public-copy regressions while retaining useful upgrade warnings."""
from pathlib import Path
import runpy
import unittest

CHECK = runpy.run_path(str(Path(__file__).with_name('check-public-branding.py')))['release_errors']
CHECKSUMS = runpy.run_path(str(Path(__file__).with_name('check-public-branding.py')))['checksum_errors']


class ReleaseCopyTests(unittest.TestCase):
    def release(self):
        base = 'https://github.com/uuthings/DeskDen/releases/download/v0.3.0/'
        return {'tag_name': 'v0.3.0', 'name': 'DeskDen v0.3.0',
                'body': '升级前导出加密备份；新版保存的资料无法在旧版打开。\n'
                        + base + 'DeskDen-0.3.0-macos-universal.dmg\n' + base + 'SHA256SUMS.txt',
                'assets': [{'name': 'DeskDen-0.3.0-macos-universal.dmg'}, {'name': 'SHA256SUMS.txt'}]}

    def test_customer_copy_and_real_upgrade_warning_are_allowed(self):
        self.assertEqual(CHECK(self.release()), [])

    def test_internal_delivery_receipt_is_rejected(self):
        value = self.release(); value['body'] += '\n本页为现在补建，未倒填发布日期。'
        self.assertTrue(CHECK(value))

    def test_title_cannot_use_another_brand_or_internal_qualifier(self):
        for title in ['方寸 0.3.0', 'Fangcun v0.3.0', 'DeskDen v0.3.0 · 历史版本']:
            value = self.release(); value['name'] = title
            self.assertTrue(CHECK(value))

    def test_wrong_version_or_missing_download_is_rejected(self):
        value = self.release(); value['body'] = value['body'].replace('v0.3.0/', 'v0.2.0/')
        self.assertTrue(CHECK(value))
        value = self.release(); value['assets'].pop(0)
        self.assertTrue(CHECK(value))

    def test_unpublished_checksum_is_rejected(self):
        value = self.release(); value['assets'].pop()
        self.assertTrue(CHECK(value))

    def test_old_brand_duplicate_package_and_fragmented_checksums_are_rejected(self):
        for name in ['Fangcun-0.3.0-macos-universal.dmg', 'Deskden-0.3.0-macos-universal.zip', 'SHA256SUMS-dmg.txt', 'SHA256SUMS-DeskDen.txt']:
            value = self.release(); value['assets'].append({'name': name})
            self.assertTrue(CHECK(value))
        value = self.release(); value['assets'].append(dict(value['assets'][0]))
        self.assertTrue(CHECK(value))

    def test_optional_connector_requires_its_download(self):
        value = self.release(); value['body'] += '\nDeskDen IPRoyal Connector'
        self.assertTrue(CHECK(value))
        value['assets'].append({'name': 'DeskDen-IPRoyal-Connector-0.1.0-chrome-macos.zip'})
        self.assertEqual(CHECK(value), [])

    def test_manifest_covers_every_binary_once_and_matches_digest(self):
        value = self.release(); name = value['assets'][0]['name']; digest = 'a' * 64
        value['assets'][0]['digest'] = 'sha256:' + digest
        text = digest + '  ' + name + '\n'
        self.assertEqual(CHECKSUMS(value, text), [])
        self.assertTrue(CHECKSUMS(value, text + text))
        self.assertTrue(CHECKSUMS(value, text.replace(digest, 'b' * 64)))
        value['assets'].append({'name': 'DeskDen-IPRoyal-Connector-0.1.0-chrome-macos.zip'})
        self.assertTrue(CHECKSUMS(value, text))


if __name__ == '__main__':
    unittest.main()
