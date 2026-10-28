#!/usr/bin/env python3
"""Reject public-copy regressions while retaining useful upgrade warnings."""
from pathlib import Path
import runpy
import unittest

CHECK = runpy.run_path(str(Path(__file__).with_name('check-public-branding.py')))['release_errors']


class ReleaseCopyTests(unittest.TestCase):
    def release(self):
        base = 'https://github.com/uuthings/DeskDen/releases/download/v0.3.0/'
        return {'tag_name': 'v0.3.0', 'name': 'DeskDen v0.3.0',
                'body': '升级前导出加密备份；新版保存的资料无法在旧版打开。\n'
                        + base + 'DeskDen-0.3.0-macos-universal.dmg\n' + base + 'SHA256SUMS-DeskDen.txt',
                'assets': [{'name': 'DeskDen-0.3.0-macos-universal.dmg'}, {'name': 'SHA256SUMS-DeskDen.txt'}]}

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


if __name__ == '__main__':
    unittest.main()
