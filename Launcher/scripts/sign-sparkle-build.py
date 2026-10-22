#!/usr/bin/env python3
"""Sign the embedded Sparkle copy during an Xcode build, before App CodeSign.

This takes no artifact path arguments. It never signs a package-cache framework,
an exported App, or the enclosing App; Xcode owns the final application signature.
"""
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess

TEAM = '97K37J92QD'
PINNED_VERSION = '2.10.0'
HELPERS = ('Versions/B/Autoupdate', 'Versions/B/Updater.app',
           'Versions/B/XPCServices/Downloader.xpc', 'Versions/B/XPCServices/Installer.xpc')


def build_context(environment):
    if environment.get('CODE_SIGNING_ALLOWED') == 'NO':
        return None
    if environment.get('ACTION') not in ('build', 'install') or not environment.get('XCODE_VERSION_ACTUAL'):
        raise SystemExit('Sparkle signing is restricted to an Xcode build or archive action')
    required = ('TARGET_BUILD_DIR', 'WRAPPER_NAME', 'FRAMEWORKS_FOLDER_PATH', 'DERIVED_FILE_DIR')
    if not all(environment.get(key) for key in required):
        raise SystemExit('Missing Xcode build-product context for Sparkle signing')
    wrapper = environment['WRAPPER_NAME']
    if Path(wrapper).name != wrapper or not wrapper.endswith('.app'):
        raise SystemExit('Unexpected Xcode application product name')
    app = Path(environment['TARGET_BUILD_DIR']).resolve() / wrapper
    framework = app / 'Contents/Frameworks/Sparkle.framework'
    configured = Path(environment['TARGET_BUILD_DIR']) / environment['FRAMEWORKS_FOLDER_PATH'] / 'Sparkle.framework'
    if (app.is_symlink() or framework.is_symlink() or configured.resolve() != framework.resolve()
            or not framework.resolve().is_relative_to(app.resolve())):
        raise SystemExit('Sparkle signing must use the embedded build-product framework')
    identity = environment.get('EXPANDED_CODE_SIGN_IDENTITY', '').strip()
    if not identity:
        raise SystemExit('Xcode did not provide its expanded signing identity')
    adhoc = identity == '-'
    if adhoc and environment.get('CONFIGURATION') != 'Debug':
        raise SystemExit('Only Debug builds may sign Sparkle ad-hoc')
    if not adhoc and environment.get('DEVELOPMENT_TEAM') != TEAM:
        raise SystemExit('Sparkle must reuse the existing application signing team')
    if not adhoc and not environment.get('EXPANDED_CODE_SIGN_IDENTITY_NAME', '').startswith('Developer ID Application:'):
        raise SystemExit('Distribution Sparkle helpers require the existing Developer ID Application identity')
    receipt = Path(environment['DERIVED_FILE_DIR']).resolve() / 'sparkle-nested-signing.json'
    return {'framework': framework, 'identity': identity, 'adhoc': adhoc, 'receipt': receipt}


def entitlements(path):
    result = subprocess.run(['/usr/bin/codesign', '--display', '--entitlements', '-', '--xml', str(path)],
                            check=True, capture_output=True)
    return plistlib.loads(result.stdout) if result.stdout.strip() else {}


def signature(path):
    result = subprocess.run(['/usr/bin/codesign', '--display', '--verbose=4', str(path)],
                            check=True, capture_output=True, text=True)
    text = result.stdout + result.stderr
    values = {}
    for key in ('Identifier', 'TeamIdentifier', 'Timestamp'):
        matches = re.findall(r'^' + key + r'=(.+)$', text, flags=re.M)
        values[key] = matches[0] if len(matches) == 1 else None
    matches = re.findall(r'^CodeDirectory (.+)$', text, flags=re.M)
    values['CodeDirectory'] = matches[0] if len(matches) == 1 else None
    return values


def sign_build_product(context):
    framework = context['framework']
    info = plistlib.loads((framework / 'Resources/Info.plist').read_bytes())
    if info.get('CFBundleShortVersionString') != PINNED_VERSION or info.get('CFBundleIdentifier') != 'org.sparkle-project.Sparkle':
        raise SystemExit('Unexpected embedded Sparkle framework identity or version')
    for path in framework.rglob('*'):
        if path.is_symlink() and not path.resolve(strict=True).is_relative_to(framework.resolve()):
            raise SystemExit('The embedded framework contains an escaping symbolic link')
    targets = [framework / name for name in HELPERS] + [framework]
    if not all(path.exists() and not path.is_symlink() for path in targets):
        raise SystemExit('The pinned Sparkle helper set is incomplete')
    receipts = []
    for path in targets:
        before_entitlements, before_signature = entitlements(path), signature(path)
        # Match Sparkle's official per-helper signing policy. Only Downloader
        # may retain its own sandbox entitlements. In particular, do not retain
        # Autoupdate's upstream application-identifier or inherit App Keychain rights.
        preserve_downloader = path.name == 'Downloader.xpc'
        expected_entitlements = before_entitlements if preserve_downloader else {}
        command = ['/usr/bin/codesign', '--force', '--sign', context['identity'],
                   '--preserve-metadata=' + ('identifier,entitlements' if preserve_downloader else 'identifier'),
                   '--generate-entitlement-der']
        if context['adhoc']:
            command += ['--timestamp=none']
        else:
            command += ['--options', 'runtime', '--timestamp']
        subprocess.run(command + [str(path)], check=True)
        subprocess.run(['/usr/bin/codesign', '--verify', '--strict', '--all-architectures', str(path)], check=True)
        after_entitlements, after_signature = entitlements(path), signature(path)
        if expected_entitlements != after_entitlements or before_signature['Identifier'] != after_signature['Identifier']:
            raise SystemExit('Sparkle signing changed a helper identity or violated its official entitlement policy')
        if not context['adhoc']:
            if (after_signature['TeamIdentifier'] != TEAM or not after_signature['Timestamp']
                    or '(runtime)' not in (after_signature['CodeDirectory'] or '')):
                raise SystemExit('A Sparkle helper lacks the required team, hardened runtime or secure timestamp')
        receipts.append({'path': path.relative_to(framework).as_posix(), 'identifier': after_signature['Identifier'],
                         'team': after_signature['TeamIdentifier'], 'timestamp': after_signature['Timestamp'],
                         'entitlementPolicy': 'preserve-own-downloader' if preserve_downloader else 'no-app-entitlements',
                         'officialEntitlementPolicyVerified': True})
    # --deep is verification only. Every nested signing action above is explicit.
    subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', '--all-architectures', str(framework)], check=True)
    receipt = {'schema': 'fangcun.sparkle-build-signing/1', 'sparkleVersion': PINNED_VERSION,
               'adHocDebug': context['adhoc'], 'buildProductOnly': True, 'helpers': receipts}
    context['receipt'].parent.mkdir(parents=True, exist_ok=True)
    context['receipt'].write_text(json.dumps(receipt, indent=2) + '\n')
    print('Embedded Sparkle helpers signed inside-out; per-helper entitlements and final framework signature verified.')


def main():
    context = build_context(os.environ)
    if context is None:
        print('Skipping Sparkle signing because Xcode CODE_SIGNING_ALLOWED=NO')
        return
    sign_build_product(context)


if __name__ == '__main__':
    main()
