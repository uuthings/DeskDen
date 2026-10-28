#!/usr/bin/env python3
"""Read-only signing policy checks; no Keychain, profile, account, or build access."""
from copy import deepcopy
import json
from pathlib import Path
import plistlib
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
ENTITLEMENTS_PATH = "Launcher/Signing/DeskDen.entitlements"
OWN_GROUP = "$(AppIdentifierPrefix)$(PRODUCT_BUNDLE_IDENTIFIER)"
EXPECTED_ENTITLEMENTS = {
    "com.apple.application-identifier": OWN_GROUP,
    "com.apple.developer.team-identifier": "$(DEVELOPMENT_TEAM)",
    "keychain-access-groups": [OWN_GROUP],
}


def policy_errors(entitlements, debug, release):
    errors = []
    if entitlements != EXPECTED_ENTITLEMENTS:
        errors.append("The template must contain only the app identifier, team, and its one default Keychain group")
    for name, settings in [("Debug", debug), ("Release", release)]:
        if settings.get("CODE_SIGN_STYLE") != "Manual":
            errors.append(name + " must preserve manual signing")
        if settings.get("PRODUCT_BUNDLE_IDENTIFIER") != "local.deskden.launcher":
            errors.append(name + " must preserve the installed Bundle ID")
        if settings.get("PROVISIONING_PROFILE_SPECIFIER", "") or settings.get("PROVISIONING_PROFILE", ""):
            errors.append(name + " must not commit a local provisioning profile selector or UUID")
    if debug.get("CODE_SIGN_IDENTITY") != "-" or debug.get("CODE_SIGN_ENTITLEMENTS", ""):
        errors.append("Debug must remain ad-hoc without restricted entitlements")
    if release.get("CODE_SIGN_IDENTITY") != "Developer ID Application" or release.get("DEVELOPMENT_TEAM") != "97K37J92QD":
        errors.append("Release must reuse the existing Developer ID team and signing style")
    if release.get("CODE_SIGN_ENTITLEMENTS") != ENTITLEMENTS_PATH:
        errors.append("Release must use the reviewed entitlement template")
    if release.get("ENABLE_HARDENED_RUNTIME") != "YES":
        errors.append("Release must keep Hardened Runtime enabled")
    return errors


def main():
    total = failures = 0

    def check(condition, title):
        nonlocal total, failures
        total += 1
        failures += not condition
        print(("PASS " if condition else "FAIL ") + title)

    template = ROOT / ENTITLEMENTS_PATH
    check(template.is_file() and not template.is_symlink(), "the public entitlement template is one regular source file")
    entitlements = plistlib.loads(template.read_bytes())
    project = json.loads(subprocess.check_output([
        "/usr/bin/plutil", "-convert", "json", "-o", "-", str(ROOT / "DeskDen.xcodeproj/project.pbxproj")
    ]))
    objects = project["objects"]
    targets = [value for value in objects.values() if value.get("isa") == "PBXNativeTarget" and value.get("name") == "DeskDen"]
    check(len(targets) == 1, "the signing check resolves the actual DeskDen application target")
    target = targets[0]
    configs = {objects[identifier]["name"]: objects[identifier]["buildSettings"] for identifier in objects[target["buildConfigurationList"]]["buildConfigurations"]}
    debug, release = configs["Debug"], configs["Release"]
    errors = policy_errors(entitlements, debug, release)
    for error in errors:
        check(False, error)
    check(not errors, "Release uses the minimal authorized-group template while Debug remains profile-free")
    check(entitlements == EXPECTED_ENTITLEMENTS, "the template adds no sandbox, app groups, wildcard, or unrelated Keychain access")
    check(all(not settings.get(key) for settings in configs.values() for key in ["PROVISIONING_PROFILE_SPECIFIER", "PROVISIONING_PROFILE"]), "profile selection is a local build override rather than committed account metadata")
    refs = {identifier: value for identifier, value in objects.items() if value.get("isa") == "PBXFileReference"}
    entitlement_refs = [identifier for identifier, value in refs.items() if value.get("path") == ENTITLEMENTS_PATH]
    check(len(entitlement_refs) == 1, "Xcode exposes exactly one reviewed entitlement source reference")
    resource_refs = {objects[build]["fileRef"] for phase in target["buildPhases"] if objects[phase].get("isa") == "PBXResourcesBuildPhase" for build in objects[phase]["files"]}
    check(not set(entitlement_refs).intersection(resource_refs), "the entitlement template is not copied as an application resource")
    diagnostic = "Launcher/Sources/DeskDenLauncher/VaultSigningChecks.swift"
    diagnostic_refs = {identifier for identifier, value in refs.items() if value.get("path") == diagnostic}
    compiled_refs = [objects[build]["fileRef"] for phase in target["buildPhases"] if objects[phase].get("isa") == "PBXSourcesBuildPhase" for build in objects[phase]["files"]]
    check(len(diagnostic_refs) == 1 and sum(reference in diagnostic_refs for reference in compiled_refs) == 1, "the read-only signing diagnostic is compiled exactly once by the native target")
    info = plistlib.loads((ROOT / "Launcher/Resources/Info.plist").read_bytes())
    check(str(release.get("MARKETING_VERSION")) == info["CFBundleShortVersionString"] and str(release.get("CURRENT_PROJECT_VERSION")) == info["CFBundleVersion"], "signing configuration preserves matching existing version and Build fields")
    local_build = (ROOT / "Launcher/scripts/build-local.sh").read_text()
    check('codesign --force --sign - "$app_path"' in local_build and "codesign --force --sign - --entitlements" not in local_build and 'embedded.provisionprofile' not in local_build, "SwiftPM local previews retain ad-hoc signing without a profile or restricted template")
    for filename in ["build-local.sh", "verify-local.sh"]:
        source = (ROOT / "Launcher/scripts" / filename).read_text()
        check(source.count("/ 'Signing/DeskDen.entitlements'") == 2 and source.count("('scripts', '*.py')") == 2, filename + " freezes the template and Python checks before and after verification")

    # Negative configuration fixtures prove that policy drift is rejected, not
    # merely that today's successful configuration is parseable.
    cases = [
        ("unrelated Keychain group", "entitlements", "keychain-access-groups", ["$(AppIdentifierPrefix)example.other"]),
        ("extra entitlement", "entitlements", "com.apple.security.app-sandbox", True),
        ("ad-hoc restricted entitlement", "debug", "CODE_SIGN_ENTITLEMENTS", ENTITLEMENTS_PATH),
        ("committed profile name", "release", "PROVISIONING_PROFILE_SPECIFIER", "Synthetic local profile"),
        ("committed profile UUID", "release", "PROVISIONING_PROFILE", "00000000-0000-0000-0000-000000000000"),
        ("changed team", "release", "DEVELOPMENT_TEAM", "SYNTHETIC1"),
        ("changed Bundle ID", "release", "PRODUCT_BUNDLE_IDENTIFIER", "example.other"),
    ]
    for name, kind, key, value in cases:
        test_entitlements, test_debug, test_release = deepcopy(entitlements), deepcopy(debug), deepcopy(release)
        {"entitlements": test_entitlements, "debug": test_debug, "release": test_release}[kind][key] = value
        check(bool(policy_errors(test_entitlements, test_debug, test_release)), "configuration policy rejects " + name)
    print(f"Signing configuration checks: {total - failures}/{total} passed")
    return int(failures != 0)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (KeyError, ValueError, OSError, plistlib.InvalidFileException, subprocess.CalledProcessError) as error:
        print("FAIL Signing configuration could not be read: " + type(error).__name__, file=sys.stderr)
        raise SystemExit(1)
