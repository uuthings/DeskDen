#!/usr/bin/env python3
"""Read-only updater policy and negative fixtures; no accounts, keys or network.

The appcast and archive signature blocks are checked structurally, not
cryptographically. Verify the real feed and archives separately with the
official Sparkle tools. A valid source feed does not prove online publication.
"""
import argparse
import base64
import binascii
from copy import deepcopy
import json
import ipaddress
import math
from pathlib import Path
import plistlib
import re
import runpy
import stat
import subprocess
import sys
from urllib.parse import urlsplit, unquote
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]
SPARKLE_URL = "https://github.com/sparkle-project/Sparkle"
SPARKLE_VERSION = "2.10.0"
# Public commit resolved from the official 2.10.0 tag, not a local checkout path.
SPARKLE_REVISION = "eef1a539a373c1f1a320624b1130fc5de7b2e100"
FEED_URL = "https://raw.githubusercontent.com/uuthings/DeskDen/main/updates/appcast.xml"
SOURCE_FILES = ["Launcher/Sources/FangcunLauncher/" + name for name in
                ("AppUpdateController.swift", "WorkbenchUpdateSettings.swift")]
SIGNING_SCRIPT = "Launcher/scripts/sign-sparkle-build.py"
SIGNING_PHASE_NAME = "Sign embedded Sparkle helpers"
SIGNING_INPUT = "$(TARGET_BUILD_DIR)/$(FRAMEWORKS_FOLDER_PATH)/Sparkle.framework"
SIGNING_OUTPUT = "$(DERIVED_FILE_DIR)/sparkle-nested-signing.json"
SIGNING_COMMAND = 'exec /usr/bin/python3 "$SRCROOT/Launcher/scripts/sign-sparkle-build.py"\n'
LOCK_FILES = ("Launcher/Package.resolved",
              "Fangcun.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved")
CHANNEL = {
    "title": "Fangcun updates",
    "link": "https://github.com/uuthings/DeskDen",
    "description": "Signed updates for Fangcun. No public update has been published.",
    "language": "zh-CN",
}
SPARKLE_NAMESPACE = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
MAX_FEED_BYTES = 2_000_000
SIGN_WARNING = ("sparkle-sign-warning: IMPORTANT: This file was signed by Sparkle. "
                "Any modifications to this file requires re-signing this file with generate_appcast "
                "or sign_update! The signed signature will be embedded at the end of this file.")
SIGNATURE_BLOCK = re.compile(
    rb"<!-- sparkle-signatures:\nedSignature: ([A-Za-z0-9+/]+={0,2})\nlength: ([0-9]+)\n-->\n\Z")


def decoded_size(value, size):
    if not isinstance(value, str):
        return False
    try:
        decoded = base64.b64decode(value, validate=True)
        return len(decoded) == size and base64.b64encode(decoded).decode("ascii") == value
    except (ValueError, binascii.Error):
        return False


def signature_shape(value):
    return decoded_size(value, 64) and len(set(base64.b64decode(value))) > 1


def numeric_version(value, parts=None):
    if not isinstance(value, str) or len(value) > 80 or not re.fullmatch(r"[0-9]+(?:\.[0-9]+){0,2}", value):
        return None
    numbers = tuple(int(part) for part in value.split("."))
    return numbers if (parts is None or len(numbers) == parts) and any(numbers) else None


def secure_public_url(value):
    if not isinstance(value, str) or re.search(r"\s|[<>]", value):
        return False
    try:
        url = urlsplit(value)
        if url.scheme != "https" or not url.hostname or url.username is not None or url.password is not None or url.fragment:
            return False
        host = url.hostname.lower()
        if host in ("localhost", "example.com", "example.org", "example.net") or host.endswith((".localhost", ".local", ".invalid", ".test", ".example")):
            return False
        try:
            if not ipaddress.ip_address(host).is_global:
                return False
        except ValueError:
            pass
        if re.search(r"(?i)(?:\b(?:TODO|TBD|placeholder|replace[_-]?me|your[_-](?:url|version|app|archive))\b)", unquote(value)):
            return False
        return url.port in (None, 443)
    except ValueError:
        return False


def configuration_errors(info):
    errors = []
    if info.get("SUFeedURL") != FEED_URL:
        errors.append("feed must use the reviewed credential-free HTTPS endpoint")
    if not decoded_size(info.get("SUPublicEDKey"), 32):
        errors.append("Ed25519 public key must contain exactly 32 canonical Base64 bytes")
    for key, expected in {
        "SUEnableAutomaticChecks": False, "SUAutomaticallyUpdate": False,
        "SUAllowsAutomaticUpdates": False, "SUSendProfileInfo": False,
        "SUVerifyUpdateBeforeExtraction": True, "SURequireSignedFeed": True,
    }.items():
        if type(info.get(key)) is not bool or info[key] is not expected:
            errors.append(key + " must be explicitly " + str(expected).lower())
    interval = info.get("SUScheduledCheckInterval")
    if type(interval) not in (int, float) or not math.isfinite(interval) or interval < 86_400:
        errors.append("automatic checks must be at least 24 hours apart")
    if numeric_version(info.get("LSMinimumSystemVersion")) is None:
        errors.append("the app must expose its actual numeric minimum macOS baseline")
    return errors


def manifest_errors(source):
    # Preserve string literals (including HTTPS) while removing Swift comments.
    clean = re.sub(r'"(?:\\.|[^"\\])*"|//[^\n]*|/\*.*?\*/',
                   lambda match: match[0] if match[0].startswith('"') else "", source, flags=re.S)
    declarations = re.findall(r'\.package\(\s*url:\s*"([^"]+)"\s*,\s*exact:\s*"([^"]+)"\s*\)', clean)
    errors = []
    if declarations.count((SPARKLE_URL, SPARKLE_VERSION)) != 1 or clean.count('"' + SPARKLE_URL + '"') != 1:
        errors.append("SwiftPM must declare exactly one official exact Sparkle 2.10.0 dependency")
    targets = re.findall(r'\.executableTarget\(\s*name:\s*"FangcunLauncher"\s*,\s*dependencies:\s*\[(.*?)\]\s*\)', clean, flags=re.S)
    if len(targets) != 1 or len(re.findall(r'\.product\(\s*name:\s*"Sparkle"\s*,\s*package:\s*"Sparkle"\s*\)', targets[0])) != 1:
        errors.append("SwiftPM native executable must link the Sparkle product exactly once")
    return errors


def normalized_pins(lock):
    if type(lock.get("version")) is not int or lock["version"] not in (2, 3) or not isinstance(lock.get("pins"), list):
        raise ValueError("unsupported package lock schema")
    pins = {}
    for pin in lock["pins"]:
        identity = pin["identity"].lower()
        if identity in pins:
            raise ValueError("duplicate package identity")
        pins[identity] = {key: pin[key] for key in ("kind", "location", "state")}
    return pins


def lock_errors(swiftpm, xcode):
    try:
        first, second = normalized_pins(swiftpm), normalized_pins(xcode)
    except (KeyError, TypeError, ValueError, AttributeError):
        return ["both package locks must have a supported unambiguous schema"]
    expected = {"kind": "remoteSourceControl", "location": SPARKLE_URL,
                "state": {"revision": SPARKLE_REVISION, "version": SPARKLE_VERSION}}
    errors = []
    if first.get("sparkle") != expected or second.get("sparkle") != expected:
        errors.append("both locks must pin the reviewed official Sparkle 2.10.0 commit without a branch")
    if first != second:
        errors.append("SwiftPM and Xcode resolved dependency pins must match")
    return errors


def project_errors(project):
    try:
        objects = project["objects"]
        root = objects[project["rootObject"]]
        if root.get("isa") != "PBXProject":
            return ["Xcode root must be its actual project object"]
        targets = [objects[key] for key in root["targets"] if objects[key].get("isa") == "PBXNativeTarget"
                   and objects[key].get("name") == "Fangcun"]
        if len(targets) != 1 or targets[0].get("productType") != "com.apple.product-type.application":
            return ["Xcode must resolve one Fangcun application target"]
        target = targets[0]
        phases = [objects[key] for key in target["buildPhases"]]
        compiled = [objects[key].get("fileRef") for phase in phases if phase.get("isa") == "PBXSourcesBuildPhase" for key in phase["files"]]
        linked = [objects[key] for phase in phases if phase.get("isa") == "PBXFrameworksBuildPhase" for key in phase["files"]]
        errors = []
        for path in SOURCE_FILES:
            refs = [key for key, value in objects.items() if value.get("isa") == "PBXFileReference" and Path(value.get("path", "")).name == Path(path).name]
            if len(refs) != 1 or objects[refs[0]].get("path") != path or objects[refs[0]].get("sourceTree") != "SOURCE_ROOT" or compiled.count(refs[0]) != 1:
                errors.append("Xcode must reference and compile " + Path(path).name + " exactly once")
        packages = [key for key, value in objects.items() if value.get("isa") == "XCRemoteSwiftPackageReference"
                    and value.get("repositoryURL", "").rstrip("/").removesuffix(".git") == SPARKLE_URL]
        if len(packages) != 1 or root.get("packageReferences", []).count(packages[0]) != 1 or objects[packages[0]].get("requirement") != {"kind": "exactVersion", "version": SPARKLE_VERSION}:
            errors.append("Xcode must reference one official exact Sparkle 2.10.0 package")
        products = [key for key, value in objects.items() if value.get("isa") == "XCSwiftPackageProductDependency" and value.get("productName") == "Sparkle"]
        if len(products) != 1 or objects[products[0]].get("package") not in packages or target.get("packageProductDependencies", []).count(products[0]) != 1 or sum(item.get("productRef") == products[0] for item in linked) != 1:
            errors.append("Xcode must depend on and link the reviewed Sparkle product exactly once")
        if any(Path(objects.get(item.get("fileRef"), {}).get("path", "")).name == "Sparkle.framework" for item in linked):
            errors.append("Xcode must not also link an unmanaged Sparkle framework copy")
        signing = [phase for phase in phases if phase.get("isa") == "PBXShellScriptBuildPhase" and phase.get("name") == SIGNING_PHASE_NAME]
        if len(signing) != 1:
            errors.append("Xcode must run exactly one embedded Sparkle helper signing phase")
        else:
            phase = signing[0]
            if (phases[-1] is not phase or phase.get("shellPath") != "/bin/sh" or phase.get("shellScript") != SIGNING_COMMAND
                    or phase.get("inputPaths") != [SIGNING_INPUT, "$(SRCROOT)/" + SIGNING_SCRIPT]
                    or phase.get("outputPaths") != [SIGNING_OUTPUT] or str(phase.get("alwaysOutOfDate")) != "1"
                    or str(phase.get("runOnlyForDeploymentPostprocessing")) != "0"):
                errors.append("Sparkle signing must follow the embedded framework dependency and precede final App signing on every build")
        configs = [objects[key] for key in objects[target["buildConfigurationList"]]["buildConfigurations"]]
        if not configs or any(config.get("buildSettings", {}).get("ENABLE_USER_SCRIPT_SANDBOXING") != "NO" for config in configs):
            errors.append("the signing phase must be able to update its embedded build product without a script sandbox denial")
        return errors
    except (KeyError, TypeError, AttributeError):
        return ["Xcode package or source graph is incomplete"]


def archive_errors(enclosure):
    errors = []
    url = enclosure.get("url")
    if not secure_public_url(url) or urlsplit(url).path in ("", "/"):
        errors.append("each archive must have a real credential-free public HTTPS download URL")
    if not signature_shape(enclosure.get(SPARKLE_NAMESPACE + "edSignature")):
        errors.append("each archive must have a non-placeholder 64-byte Ed25519 signature")
    length = enclosure.get("length", "")
    if not re.fullmatch(r"[0-9]{1,20}", length) or int(length) <= 0:
        errors.append("each archive length must be a positive integer")
    if not re.fullmatch(r"[a-z-]+/[a-z0-9.+-]+", enclosure.get("type", "")):
        errors.append("each archive must declare its MIME type")
    return errors


def release_item_errors(item, minimum_system):
    errors = []
    full = item.findall("enclosure")
    if len(full) != 1:
        return ["each release must contain exactly one full update enclosure"]
    enclosure = full[0]

    def scalar(name, legacy=False):
        elements = item.findall(SPARKLE_NAMESPACE + name)
        values = [element.text for element in elements if not list(element)]
        if legacy and enclosure.get(SPARKLE_NAMESPACE + name) is not None:
            values.append(enclosure.get(SPARKLE_NAMESPACE + name))
        return values[0] if len(values) == 1 else None

    if numeric_version(scalar("version", legacy=True)) is None:
        errors.append("each release must expose one real nonzero numeric Build version")
    if numeric_version(scalar("shortVersionString", legacy=True), parts=3) is None:
        errors.append("each release must expose one real three-part short version")
    minimum, floor = numeric_version(scalar("minimumSystemVersion")), numeric_version(minimum_system)
    if minimum is None or floor is None or minimum + (0,) * (3 - len(minimum)) < floor + (0,) * (3 - len(floor)):
        errors.append("each release minimum macOS must be explicit and no lower than the app baseline")
    titles = item.findall("title")
    if len(titles) != 1 or not (titles[0].text or "").strip():
        errors.append("each release must have one nonempty public title")
    for element in item:
        if not element.tag.startswith(SPARKLE_NAMESPACE) and element.tag not in ("title", "description", "pubDate", "link", "enclosure"):
            errors.append("release item contains an unknown RSS field")
        if element.tag in ("title", "description") and re.search(r"(?i)\b(?:TODO|TBD|placeholder|replace[_-]?me|your[_-]version|synthetic)\b", "".join(element.itertext())):
            errors.append("release metadata must not contain fictional placeholder content")
        if element.tag in ("link", SPARKLE_NAMESPACE + "releaseNotesLink", SPARKLE_NAMESPACE + "fullReleaseNotesLink") and not secure_public_url(element.text):
            errors.append("release and release-note links must use public HTTPS URLs")
    deltas = item.findall(SPARKLE_NAMESPACE + "deltas")
    if len(deltas) > 1 or any(child.tag != "enclosure" for group in deltas for child in group):
        errors.append("delta containers must contain only update enclosures")
    archives = full + [child for group in deltas for child in group if child.tag == "enclosure"]
    if any(element not in archives for element in item.iter("enclosure")):
        errors.append("release contains an unexpected nested update enclosure")
    for archive in archives:
        errors.extend(archive_errors(archive))
        if archive is not enclosure and numeric_version(archive.get(SPARKLE_NAMESPACE + "deltaFrom")) is None:
            errors.append("delta archive must identify its actual numeric source Build")
    return errors


def feed_errors(data, minimum_system="14.0"):
    errors = []
    if not isinstance(data, bytes) or len(data) > MAX_FEED_BYTES:
        return ["source feed must be a bounded public XML document"]
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError:
        return ["source feed must use UTF-8"]
    if re.search(r"(?i)(?:file://|/(?:Users|home|Volumes|private|tmp|var/folders)/|[A-Z]:\\Users\\|-----BEGIN [A-Z ]*PRIVATE KEY-----|(?:token|password|secret|api[_-]?key|private[_-]?key)\s*[:=]|gh[pousr]_[A-Za-z0-9]|github_pat_|sk-[A-Za-z0-9]|[\w.+-]+@[\w.-]+\.[A-Za-z]{2,})", text):
        errors.append("source feed must not contain secrets, account metadata or local paths")
    block = SIGNATURE_BLOCK.search(data)
    if data.count(b"<!-- sparkle-signatures:") != 1 or block is None or not signature_shape(block[1].decode("ascii")) or int(block[2]) != block.start():
        errors.append("source feed must end in one official-format Ed25519 signature block with its exact content length")
    comments = re.findall(r"<!--(.*?)-->", text, flags=re.S)
    warnings = 0
    for comment in comments:
        normalized = " ".join(comment.split())
        if normalized == SIGN_WARNING:
            warnings += 1
        elif not normalized.startswith("sparkle-signatures:"):
            errors.append("source feed comments may contain only Sparkle signing metadata")
    if warnings > 1:
        errors.append("source feed has duplicate Sparkle signing warnings")
    if re.search(r"<\?(?!xml(?:\s|\?>))", text):
        errors.append("source feed must not contain processing instructions")
    if re.search(r"<!DOCTYPE|<!ENTITY", text, flags=re.I):
        return errors + ["source feed must not declare DTDs or entities"]
    try:
        rss = ET.fromstring(data)
        channels = list(rss)
        valid = rss.tag == "rss" and rss.attrib == {"version": "2.0"} and len(channels) == 1 and channels[0].tag == "channel"
        if valid:
            channel = channels[0]
            children = list(channel)
            items = channel.findall("item")
            metadata = [element for element in children if element.tag != "item"]
            valid = not channel.attrib and len(items) <= 200
            valid = valid and not (rss.text or "").strip() and not (channel.text or "").strip() and not (channel.tail or "").strip()
            if not items:
                valid = valid and len(metadata) == len(CHANNEL) and {item.tag for item in metadata} == set(CHANNEL)
                valid = valid and all(not item.attrib and not list(item) and item.text == CHANNEL[item.tag] and not (item.tail or "").strip() for item in metadata)
            else:
                valid = valid and len([element for element in metadata if element.tag == "title" and (element.text or "").strip()]) == 1
                valid = valid and len({element.tag for element in metadata}) == len(metadata)
                valid = valid and all(element.tag in (*CHANNEL, "lastBuildDate") and not element.attrib and not list(element) and (element.text or "").strip() for element in metadata)
                valid = valid and all(secure_public_url(element.text) for element in metadata if element.tag == "link")
                valid = valid and all(not item.attrib and not (item.tail or "").strip() for item in items)
                versions = []
                for item in items:
                    errors.extend(release_item_errors(item, minimum_system))
                    enclosure = item.find("enclosure")
                    versions.append(item.findtext(SPARKLE_NAMESPACE + "version") or (enclosure.get(SPARKLE_NAMESPACE + "version") if enclosure is not None else None))
                if len(set(versions)) != len(versions):
                    errors.append("release Build versions must not be duplicated")
        if not valid:
            errors.append("source feed must contain the reviewed empty channel or a valid public release channel")
    except (ET.ParseError, KeyError):
        errors.append("source feed must be valid initial-channel XML")
    return errors


def read_regular(path, limit=2_000_000):
    metadata = path.lstat()
    if not stat.S_ISREG(metadata.st_mode) or metadata.st_size > limit:
        raise ValueError("policy input must be a bounded regular source file")
    return path.read_bytes()


def run_fixtures(check):
    info = {"SUFeedURL": FEED_URL, "SUPublicEDKey": base64.b64encode(bytes(range(32))).decode(), "LSMinimumSystemVersion": "14.0",
            "SUScheduledCheckInterval": 86_400,
            **{key: False for key in ("SUEnableAutomaticChecks", "SUAutomaticallyUpdate", "SUAllowsAutomaticUpdates", "SUSendProfileInfo")},
            "SUVerifyUpdateBeforeExtraction": True, "SURequireSignedFeed": True}
    check(not configuration_errors(info), "a synthetic safe updater configuration passes the pure policy")
    for key, value in [("SUFeedURL", "http://example.invalid/appcast.xml"), ("SUFeedURL", "https://user:password@example.invalid/feed"),
                       ("SUPublicEDKey", base64.b64encode(bytes(31)).decode()), ("SUPublicEDKey", base64.b64encode(bytes(64)).decode()),
                       ("SUPublicEDKey", "not-base64"), ("SUEnableAutomaticChecks", True), ("SUEnableAutomaticChecks", 0),
                       ("SUAutomaticallyUpdate", True), ("SUAllowsAutomaticUpdates", True), ("SUSendProfileInfo", True),
                       ("SUVerifyUpdateBeforeExtraction", False), ("SURequireSignedFeed", False),
                       ("SUScheduledCheckInterval", 3600), ("SUScheduledCheckInterval", True), ("SUScheduledCheckInterval", float("nan"))]:
        changed = deepcopy(info); changed[key] = value
        check(bool(configuration_errors(changed)), "configuration rejects unsafe " + key + " fixture")
    for key in ("SUEnableAutomaticChecks", "SUAutomaticallyUpdate", "SUAllowsAutomaticUpdates", "SUVerifyUpdateBeforeExtraction", "SURequireSignedFeed"):
        changed = deepcopy(info); del changed[key]
        check(bool(configuration_errors(changed)), "configuration rejects missing explicit " + key)
    manifest = '.package(url: "' + SPARKLE_URL + '", exact: "2.10.0")\n.executableTarget(name: "FangcunLauncher", dependencies: ["LauncherCore", .product(name: "Sparkle", package: "Sparkle")])'
    check(not manifest_errors(manifest), "a synthetic fixed dependency and executable link pass the manifest policy")
    for name, changed in [("version range", manifest.replace("exact:", "from:")), ("different release", manifest.replace("2.10.0", "2.9.0")),
                          ("untrusted repository", manifest.replace(SPARKLE_URL, "https://example.invalid/Sparkle")),
                          ("missing executable product", manifest.replace('name: "Sparkle"', 'name: "Other"')),
                          ("comment-only dependency", "// " + manifest.splitlines()[0] + "\n" + manifest.splitlines()[1])]:
        check(bool(manifest_errors(changed)), "manifest rejects " + name)
    lock = {"version": 3, "pins": [{"identity": "sparkle", "kind": "remoteSourceControl", "location": SPARKLE_URL,
                                  "state": {"version": SPARKLE_VERSION, "revision": SPARKLE_REVISION}}]}
    check(not lock_errors(lock, deepcopy(lock)), "identical synthetic reviewed pins pass both-lock policy")
    for name, field, value in [("changed locked release", "version", "2.9.0"), ("changed locked commit", "revision", "0" * 40), ("floating locked branch", "branch", "main")]:
        changed = deepcopy(lock); changed["pins"][0]["state"][field] = value
        check(bool(lock_errors(changed, changed)), "locks reject " + name + " even when both files agree")
    changed = deepcopy(lock); changed["pins"] = []
    check(bool(lock_errors(lock, changed)), "locks reject a missing Xcode pin and differing dependency graphs")
    changed = deepcopy(lock); changed["pins"] *= 2
    check(bool(lock_errors(changed, changed)), "locks reject duplicate identities")
    objects = {"project": {"isa": "PBXProject", "targets": ["target"], "packageReferences": ["package"]},
               "target": {"isa": "PBXNativeTarget", "name": "Fangcun", "productType": "com.apple.product-type.application", "buildPhases": ["sources", "frameworks", "signing"], "packageProductDependencies": ["product"], "buildConfigurationList": "configs"},
               "sources": {"isa": "PBXSourcesBuildPhase", "files": ["compile0", "compile1"]},
               "frameworks": {"isa": "PBXFrameworksBuildPhase", "files": ["link"]},
               "signing": {"isa": "PBXShellScriptBuildPhase", "name": SIGNING_PHASE_NAME, "shellPath": "/bin/sh", "shellScript": SIGNING_COMMAND,
                           "inputPaths": [SIGNING_INPUT, "$(SRCROOT)/" + SIGNING_SCRIPT], "outputPaths": [SIGNING_OUTPUT],
                           "alwaysOutOfDate": "1", "runOnlyForDeploymentPostprocessing": "0"},
               "configs": {"buildConfigurations": ["debug", "release"]},
               "debug": {"buildSettings": {"ENABLE_USER_SCRIPT_SANDBOXING": "NO"}},
               "release": {"buildSettings": {"ENABLE_USER_SCRIPT_SANDBOXING": "NO"}},
               "package": {"isa": "XCRemoteSwiftPackageReference", "repositoryURL": SPARKLE_URL, "requirement": {"kind": "exactVersion", "version": SPARKLE_VERSION}},
               "product": {"isa": "XCSwiftPackageProductDependency", "package": "package", "productName": "Sparkle"}, "link": {"productRef": "product"}}
    for index, path in enumerate(SOURCE_FILES):
        objects["source" + str(index)] = {"isa": "PBXFileReference", "path": path, "sourceTree": "SOURCE_ROOT"}
        objects["compile" + str(index)] = {"fileRef": "source" + str(index)}
    project = {"rootObject": "project", "objects": objects}
    check(not project_errors(project), "a synthetic native source and linked-product graph passes Xcode policy")
    for name, mutate in [
        ("missing settings compilation", lambda o: o["sources"]["files"].remove("compile1")),
        ("duplicate updater compilation", lambda o: o["sources"]["files"].append("compile0")),
        ("duplicate settings source reference", lambda o: o.update({"duplicate": deepcopy(o["source1"])})),
        ("aliased updater source reference", lambda o: o.update({"alias": {"isa": "PBXFileReference", "path": "AppUpdateController.swift", "sourceTree": "<group>"}})),
        ("missing Sparkle link", lambda o: o["frameworks"].update(files=[])),
        ("duplicate Sparkle link", lambda o: o["frameworks"]["files"].append("link")),
        ("missing target product", lambda o: o["target"].update(packageProductDependencies=[])),
        ("floating Xcode requirement", lambda o: o["package"].update(requirement={"kind": "upToNextMajorVersion", "minimumVersion": "2.10.0"})),
        ("untrusted Xcode package", lambda o: o["package"].update(repositoryURL="https://example.invalid/Sparkle")),
        ("missing helper signing phase", lambda o: o["target"]["buildPhases"].remove("signing")),
        ("early helper signing phase", lambda o: o["target"].update(buildPhases=["signing", "sources", "frameworks"])),
        ("missing embedded framework dependency", lambda o: o["signing"].update(inputPaths=[])),
        ("signing a package cache instead of the product", lambda o: o["signing"].update(inputPaths=["$(BUILD_DIR)/SourcePackages/artifacts/Sparkle.framework", "$(SRCROOT)/" + SIGNING_SCRIPT])),
        ("substituted helper signing command", lambda o: o["signing"].update(shellScript="codesign --deep --sign - cache.framework\n")),
        ("skippable helper signing phase", lambda o: o["signing"].update(alwaysOutOfDate="0")),
        ("sandboxed mutable signing output", lambda o: o["release"]["buildSettings"].update(ENABLE_USER_SCRIPT_SANDBOXING="YES")),
    ]:
        changed = deepcopy(project); mutate(changed["objects"])
        check(bool(project_errors(changed)), "Xcode rejects " + name)
    signing_context = runpy.run_path(str(ROOT / SIGNING_SCRIPT))["build_context"]
    environment = {"ACTION": "build", "XCODE_VERSION_ACTUAL": "2700", "CODE_SIGNING_ALLOWED": "YES",
                   "TARGET_BUILD_DIR": "/test/Build/Products/Release", "WRAPPER_NAME": "Fangcun.app",
                   "FRAMEWORKS_FOLDER_PATH": "Fangcun.app/Contents/Frameworks", "DERIVED_FILE_DIR": "/test/Build/Derived",
                   "EXPANDED_CODE_SIGN_IDENTITY": "a" * 40, "EXPANDED_CODE_SIGN_IDENTITY_NAME": "Developer ID Application: Synthetic Maintainer",
                   "DEVELOPMENT_TEAM": "97K37J92QD", "CONFIGURATION": "Release"}
    check(signing_context(environment) is not None, "helper signing accepts a synthetic Xcode build product without accessing a signing key")
    check(signing_context({"CODE_SIGNING_ALLOWED": "NO"}) is None, "unsigned CI skips helper signing before requiring any artifact or identity")
    debug = dict(environment, CONFIGURATION="Debug", EXPANDED_CODE_SIGN_IDENTITY="-")
    check(signing_context(debug)["adhoc"], "the Xcode Debug helper path remains ad-hoc")
    archive = dict(environment, ACTION="install")
    check(signing_context(archive) is not None, "archive build products use the same helper gate without signing an Organizer export")
    for name, key, value in [("Organizer export action", "ACTION", "export"), ("unknown action", "ACTION", ""),
                             ("missing expanded identity", "EXPANDED_CODE_SIGN_IDENTITY", ""),
                             ("ad-hoc Release identity", "EXPANDED_CODE_SIGN_IDENTITY", "-"),
                             ("changed Developer ID team", "DEVELOPMENT_TEAM", "SYNTHETIC1"),
                             ("unexpected identity type", "EXPANDED_CODE_SIGN_IDENTITY_NAME", "Apple Development: Synthetic Maintainer"),
                             ("framework outside the App product", "FRAMEWORKS_FOLDER_PATH", "../cache"),
                             ("non-application product", "WRAPPER_NAME", "Sparkle.framework")]:
        changed = dict(environment); changed[key] = value
        try:
            signing_context(changed)
        except SystemExit:
            check(True, "helper signing rejects " + name)
        else:
            check(False, "helper signing rejects " + name)
    xml = ('<?xml version="1.0" encoding="utf-8"?>\n<rss version="2.0"><channel>' +
           "".join("<" + key + ">" + value + "</" + key + ">" for key, value in CHANNEL.items()) + "</channel></rss>\n").encode()

    def signed_fixture(content):
        # Synthetic public bytes exercise only the envelope parser. These are
        # deliberately not real signatures and are never written as an appcast.
        return content + ("<!-- sparkle-signatures:\nedSignature: " + base64.b64encode(bytes(range(64))).decode() + "\nlength: " + str(len(content)) + "\n-->\n").encode()

    check(not feed_errors(signed_fixture(xml)), "a synthetic empty feed passes structural policy without claiming cryptographic verification")
    for name, content in [("an incomplete release item", xml.replace(b"</channel>", b"<item><title>Synthetic update</title></item></channel>")),
                          ("a local path", xml + b"<!-- /" + b"Users/synthetic/private-build -->\n"),
                          ("a secret", xml + b"<!-- token=SYNTHETIC_SENTINEL -->\n"),
                          ("an account", xml + b"<!-- synthetic@example.invalid -->\n"),
                          ("an undeclared comment", xml + b"<!-- synthetic authorization diary -->\n"),
                          ("a processing instruction", xml + b"<?synthetic private-review?>\n"),
                          ("a DTD", xml.replace(b"<rss", b'<!DOCTYPE rss [<!ENTITY synthetic "value">]><rss')),
                          ("an extra channel", xml.replace(b"</rss>", b"<channel/></rss>")),
                          ("an unknown channel field", xml.replace(b"</channel>", b"<extra>synthetic</extra></channel>"))]:
        check(bool(feed_errors(signed_fixture(content))), "feed rejects " + name)
    signed = signed_fixture(xml)
    for name, changed in [("unsigned feed", xml), ("changed signed length", b" " + signed),
                          ("short signature", signed.replace(base64.b64encode(bytes(range(64))), base64.b64encode(bytes(32)))),
                          ("placeholder signature", signed.replace(base64.b64encode(bytes(range(64))), base64.b64encode(bytes(64)))),
                          ("duplicate signature block", signed + signed[len(xml):])]:
        check(bool(feed_errors(changed)), "feed rejects " + name)
    archive_signature = base64.b64encode(bytes(range(1, 65))).decode()
    item = ('<item><title>0.1.1</title><sparkle:version>3</sparkle:version>'
            '<sparkle:shortVersionString>0.1.1</sparkle:shortVersionString>'
            '<sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>'
            '<description><![CDATA[Public release notes.]]></description>'
            '<enclosure url="https://github.com/uuthings/DeskDen/releases/download/v0.1.1/Fangcun-0.1.1.zip" '
            'length="4096" type="application/octet-stream" sparkle:edSignature="' + archive_signature + '"/></item>')

    def release_feed(contents):
        return xml.replace(b'<rss version="2.0">', b'<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">').replace(b"</channel>", contents.encode() + b"</channel>")

    check(not feed_errors(signed_fixture(release_feed(item))), "a structurally valid future release passes the same feed policy")
    legacy = item.replace('<sparkle:version>3</sparkle:version>', '').replace('<sparkle:shortVersionString>0.1.1</sparkle:shortVersionString>', '').replace('<enclosure ', '<enclosure sparkle:version="3" sparkle:shortVersionString="0.1.1" ')
    check(not feed_errors(signed_fixture(release_feed(legacy))), "valid legacy enclosure version attributes remain compatible")
    delta = '<sparkle:deltas><enclosure url="https://github.com/uuthings/DeskDen/releases/download/v0.1.1/Fangcun-3-2.delta" length="2048" type="application/octet-stream" sparkle:deltaFrom="2" sparkle:edSignature="' + archive_signature + '"/></sparkle:deltas>'
    check(not feed_errors(signed_fixture(release_feed(item.replace('</item>', delta + '</item>')))), "a future release with a valid signed delta also passes structural policy")
    for name, changed in [
        ("HTTP download", item.replace('https://github.com', 'http://github.com')),
        ("local download", item.replace('https://github.com', 'https://127.0.0.1')),
        ("fictional download", item.replace('https://github.com', 'https://example.invalid')),
        ("placeholder download", item.replace('Fangcun-0.1.1.zip', 'YOUR_ARCHIVE.zip')),
        ("missing Build", item.replace('<sparkle:version>3</sparkle:version>', '')),
        ("placeholder Build", item.replace('<sparkle:version>3</sparkle:version>', '<sparkle:version>YOUR_VERSION</sparkle:version>')),
        ("empty short version", item.replace('<sparkle:shortVersionString>0.1.1</sparkle:shortVersionString>', '<sparkle:shortVersionString/>')),
        ("malformed short version", item.replace('<sparkle:shortVersionString>0.1.1</sparkle:shortVersionString>', '<sparkle:shortVersionString>later</sparkle:shortVersionString>')),
        ("zero archive length", item.replace('length="4096"', 'length="0"')),
        ("negative archive length", item.replace('length="4096"', 'length="-1"')),
        ("short archive signature", item.replace(archive_signature, base64.b64encode(bytes(32)).decode())),
        ("placeholder archive signature", item.replace(archive_signature, base64.b64encode(bytes(64)).decode())),
        ("lower unsupported OS", item.replace('>14.0<', '>13.0<')),
        ("absent minimum OS", item.replace('<sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>', '')),
        ("fictional metadata", item.replace('<title>0.1.1</title>', '<title>TBD release</title>')),
        ("duplicate Builds", item + item),
        ("unsigned delta", item.replace('</item>', delta.replace('sparkle:edSignature="' + archive_signature + '"', '') + '</item>')),
    ]:
        check(bool(feed_errors(signed_fixture(release_feed(changed)))), "release policy rejects " + name)


def main(dependencies_only=False):
    total = failures = 0

    def check(condition, title):
        nonlocal total, failures
        total += 1; failures += not condition
        print(("PASS " if condition else "FAIL ") + title)

    def policy(errors, title):
        check(not errors, title)
        for error in errors:
            print("DETAIL " + error)

    if not dependencies_only:
        info = plistlib.loads(read_regular(ROOT / "Launcher/Resources/Info.plist"))
        policy(configuration_errors(info), "updater uses HTTPS, a 32-byte public key, manual defaults and signed daily checks")
    policy(manifest_errors(read_regular(ROOT / "Launcher/Package.swift").decode()), "SwiftPM pins and links official Sparkle 2.10.0")
    first, second = (json.loads(read_regular(ROOT / path)) for path in LOCK_FILES)
    policy(lock_errors(first, second), "SwiftPM and Xcode locks contain identical reviewed dependency pins")
    project_path = ROOT / "Fangcun.xcodeproj/project.pbxproj"
    read_regular(project_path)
    project = json.loads(subprocess.check_output(["/usr/bin/plutil", "-convert", "json", "-o", "-", str(project_path)]))
    policy(project_errors(project), "Xcode compiles both update sources once and links the fixed Sparkle product once")
    if not dependencies_only:
        feed = read_regular(ROOT / "updates/appcast.xml", MAX_FEED_BYTES)
        issues = feed_errors(feed, info.get("LSMinimumSystemVersion"))
        policy(issues, "source feed has a valid signed envelope and safe empty-channel or release metadata")
        if not issues:
            count = len(ET.fromstring(feed).findall("./channel/item"))
            print("INFO Source feed release entries: " + str(count) + "; source presence does not prove online publication.")
    run_fixtures(check)
    label = "Update dependency checks" if dependencies_only else "Update configuration checks"
    print(f"{label}: {total - failures}/{total} passed")
    print("Feed signature envelope only; real signature verification remains a separate official-tool check.")
    return int(failures != 0)


if __name__ == "__main__":
    try:
        parser = argparse.ArgumentParser(description=__doc__)
        parser.add_argument("--dependencies-only", action="store_true", help="Check actual manifest/locks/Xcode and pure fixtures without reading the unsigned source feed")
        raise SystemExit(main(parser.parse_args().dependencies_only))
    except (KeyError, TypeError, ValueError, OSError, plistlib.InvalidFileException, subprocess.CalledProcessError) as error:
        print("FAIL Update configuration could not be read: " + type(error).__name__, file=sys.stderr)
        raise SystemExit(1)
