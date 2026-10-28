#!/usr/bin/env python3
"""Update-export gate regressions; no real signing, keys, network or App access."""
from copy import deepcopy
from pathlib import Path
import plistlib
import runpy
import subprocess
import unittest

ROOT = Path(__file__).resolve().parent.parent
PREPARATION = runpy.run_path(str(ROOT / 'tools/prepare-update-feed.py'))


class ExportPreparationTests(unittest.TestCase):
    def setUp(self):
        self.info = plistlib.loads((ROOT / 'Launcher/Resources/Info.plist').read_bytes())
        self.app = Path('/test/Synthetic.app')
        self.commands = []

    def verify(self, *, identifier='local.deskden.launcher', team='97K37J92QD', architectures='arm64 x86_64', fail=None):
        def run(command, **options):
            self.commands.append(command)
            if fail and (fail in command or (fail == 'requirement' and any(value.startswith('-R=') for value in command))):
                raise subprocess.CalledProcessError(1, command)
            return subprocess.CompletedProcess(command, 0, stdout='',
                stderr='Identifier=' + identifier + '\nTeamIdentifier=' + team + '\n')

        def output(command, **options):
            self.commands.append(command)
            return architectures

        return PREPARATION['verify_exported_app'](self.app, self.info, runner=run, read_output=output)

    def test_current_metadata_and_identity_are_accepted(self):
        self.assertEqual(PREPARATION['exported_metadata_errors'](self.info, self.info), [])
        receipt = self.verify()
        self.assertEqual(receipt['architectures'], ['arm64', 'x86_64'])
        self.assertEqual(receipt['teamIdentifier'], '97K37J92QD')
        self.assertTrue(any('-R=anchor apple generic and certificate leaf[subject.OU] = "97K37J92QD" and identifier "local.deskden.launcher"' in command for command in self.commands))
        self.assertTrue(any('stapler' in command for command in self.commands))
        self.assertTrue(any('spctl' in command for command in self.commands))
        self.assertFalse(any('--sign' in command or '--force' in command or 'submit' in command for command in self.commands))

    def test_each_exported_configuration_field_is_checked(self):
        for key in PREPARATION['EXPORTED_INFO_KEYS']:
            changed = deepcopy(self.info)
            changed[key] = not changed[key] if type(changed[key]) is bool else ('different' if isinstance(changed[key], str) else 7)
            with self.subTest(key=key):
                self.assertTrue(PREPARATION['exported_metadata_errors'](changed, self.info))
            del changed[key]
            with self.subTest(missing=key):
                self.assertTrue(PREPARATION['exported_metadata_errors'](changed, self.info))

    def test_unsafe_export_is_rejected_even_if_source_were_also_changed(self):
        for key, value in [('SUAutomaticallyUpdate', True), ('SUAllowsAutomaticUpdates', True),
                           ('SUSendProfileInfo', True), ('SUEnableAutomaticChecks', True),
                           ('SUScheduledCheckInterval', 60), ('SURequireSignedFeed', False),
                           ('SUVerifyUpdateBeforeExtraction', False), ('SUFeedURL', 'http://example.invalid/feed')]:
            changed = deepcopy(self.info); changed[key] = value
            with self.subTest(key=key):
                self.assertTrue(PREPARATION['exported_metadata_errors'](changed, changed))

    def test_wrong_team_or_signed_identity_stops_before_notarization(self):
        for arguments in [{'team': 'SYNTHETIC1'}, {'identifier': 'example.other'}]:
            self.commands.clear()
            with self.subTest(arguments=arguments), self.assertRaises(SystemExit):
                self.verify(**arguments)
            self.assertFalse(any('stapler' in command or 'spctl' in command for command in self.commands))

    def test_single_or_unexpected_architectures_cannot_be_labelled_universal(self):
        for architectures in ['arm64', 'x86_64', '', 'arm64 x86_64 arm64e']:
            self.commands.clear()
            with self.subTest(architectures=architectures), self.assertRaises(SystemExit):
                self.verify(architectures=architectures)
            self.assertFalse(any('stapler' in command or 'spctl' in command for command in self.commands))

    def test_failed_apple_requirement_or_notarization_is_not_ignored(self):
        for fail in ['--deep', 'requirement', 'stapler', 'spctl']:
            with self.subTest(fail=fail), self.assertRaises(subprocess.CalledProcessError):
                self.verify(fail=fail)

    def test_executable_path_cannot_escape_its_bundle(self):
        for executable in ['../other', '/test/other', '.', '..', '']:
            changed = deepcopy(self.info); changed['CFBundleExecutable'] = executable
            with self.subTest(executable=executable):
                self.assertTrue(PREPARATION['exported_metadata_errors'](changed, changed))


if __name__ == '__main__':
    unittest.main()
