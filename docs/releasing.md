# macOS release process

Version 0.1.0 (Build 2) was signed, notarized through Organizer and retained as a local delivery, without a public Release. Version 0.2.0 (Build 3) is the first public distribution. This document describes the required process; the matching Release and each candidate's retained evidence establish the actual distribution result.

## Candidate and version

Finish changes and verification, set the source version and Build, and record the actual Git commit, Xcode/SDK versions and build arguments. Use a distinct directory for each candidate; retain old apps and designs. An ordinary commit does not authorize version changes, tags, pushes or Releases.

Reuse the existing Bundle ID, team and valid Developer ID. Signing keys stay in the local Keychain. Each new build needs signing and notarization; never re-sign an already notarized exported app.

Private Space's optional Touch ID requires an Apple-authorized provisioning profile for the existing app identifier and its own Keychain access group. Configure the matching app identifier, team identifier and Keychain group entitlements in the signed build, and embed the matching profile. Do not substitute an ad-hoc signature or an unprotected Keychain item. Local development builds without this authorization keep password unlock and explicitly report Touch ID as unavailable. Profiles, credentials and private keys are not source files.

## Local builds and Touch ID authorization

`Launcher/scripts/build-local.sh` remains an ad-hoc SwiftPM preview builder for both Debug and Release. It does not apply restricted entitlements, embed a profile, or enable Touch ID. The Xcode Debug target also remains ad-hoc with no restricted entitlement template. Password unlock remains available in these previews.

The Xcode Release target uses `Launcher/Signing/Fangcun.entitlements`. It contains only the app identifier, team identifier and the app's own default Keychain group, expanded from the matching profile's `AppIdentifierPrefix` and the unchanged Bundle ID `local.fangcun.launcher`. It requests no shared App Groups or additional Keychain groups. The existing manual Developer ID signing style and team remain unchanged.

Before building an authorized local preview:

1. In the existing Apple Developer team, register or select the explicit macOS App ID for the existing Bundle ID, then obtain a Developer ID provisioning profile authorizing its own default Keychain group and the existing Developer ID Application certificate. A template or self-asserted entitlement cannot replace this Apple authorization. Do not create a new certificate just to obtain a profile.
2. Download and install the profile locally. Keep profiles, credentials, certificate private keys and account sessions outside Git. Do not commit a profile name, UUID, machine path or private `.xcconfig`.
3. Select the installed profile by a local `PROVISIONING_PROFILE_SPECIFIER` build override. The repository deliberately leaves this setting empty. For example, set `FANGCUN_LOCAL_PROFILE` locally to the installed profile's display name, then build without uploading:

```sh
FANGCUN_PREVIEW_BUILD="$PWD/build/authorized-preview-$(date -u +%Y%m%dT%H%M%SZ)"
xcodebuild -project Fangcun.xcodeproj -scheme Fangcun -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath "$FANGCUN_PREVIEW_BUILD" \
  build PROVISIONING_PROFILE_SPECIFIER="$FANGCUN_LOCAL_PROFILE" CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO
```

A properly signed result includes `Contents/embedded.provisionprofile` and expanded matching app identifier, team and Keychain group entitlements. The build must fail if the selected profile does not authorize them; do not bypass this with unrestricted groups or weakened storage. Building a local preview does not authorize Archive, notarization, uploading or publication.

The read-only diagnostic can verify the resulting executable without opening the app or vault:

```sh
"$FANGCUN_PREVIEW_BUILD/Build/Products/Release/方寸.app/Contents/MacOS/FangcunLauncher" --vault-signing-check
```

Its JSON reports `signingStatus` separately from `hardwareStatus`. Exit 0 means that signing/profile preflight and the system's no-interaction Keychain metadata authorization succeeded. Touch ID hardware may still be unavailable; this is reported independently. Missing authorization exits 1 and keeps Touch ID unavailable. The diagnostic never enrolls, authenticates, reads a vault key or changes Keychain data. Real enrollment is a separate, explicit action by the user in Private Space.

`python3 Launcher/scripts/check-signing-config.py` checks the repository wiring and negative configuration fixtures without building, signing or accessing accounts. Local build and verification manifests include the entitlement template and Python checks before and after the run. This configuration check cannot prove that a particular installed profile is authorized; use the signed executable's diagnostic for that result.

Apple's [Mac Keychain implementation note](https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains), [provisioning profile explanation](https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles), and [manual distribution signing guide](https://help.apple.com/xcode/mac/current/en.lproj/devcac6ab5b3.html) describe the required authorization and profile selection.

## Archive and Organizer

1. Create a real `.xcarchive` with Xcode Archive or `xcodebuild archive`, under the default `~/Library/Developer/Xcode/Archives/`, and confirm that Organizer lists it.
2. Submit from Organizer using **Distribute App / Direct Distribution**, or **Developer ID / Upload**.
3. Wait for **Ready to distribute**, then export the notarized app from that same archive.
4. Check the exported app's signature, Developer ID, Hardened Runtime, architectures, ticket and Gatekeeper assessment before packaging.

Independent `notarytool submit` uploads of an App or ZIP do not replace Organizer distribution. If login, validation or notarization is blocked, retain the candidate/evidence and record the actual obstacle. Command-line status queries, log downloads and ticket/signature checks are allowed.

DMG/PKG signing and notarization have independent container records, which are not claimed as Organizer history. Generate checksums only after all packaging, signing and stapling changes; verify the final distributed bytes.

## Installers and update artifacts

For subsequent direct-distribution releases, provide a drag-install DMG containing the App and an `Applications` link. Declare the manual installer, updater artifact, public checksum manifest and release notes before preparing a release. Sparkle supports DMG as well as ZIP: the same verified DMG may serve both installation and updating. Separate ZIP update artifacts remain supported when deliberately selected and tested; ZIP is a valid distribution format, but generating an update ZIP alone does not satisfy the DMG first-install delivery requirement.

To prepare a DMG from an existing durable Organizer release without rebuilding or changing that release:

```sh
python3 tools/prepare-dmg.py --release-directory "$ORIGINAL_RELEASE_ARCHIVE" \
  --output "$NEW_PERSISTENT_SUPPLEMENT_DIRECTORY" \
  --identity "$EXISTING_DEVELOPER_ID_CERTIFICATE_SHA1"
```

Use a unique directory under the product's `ReleaseSupplements/` directory, outside Git and caches. The tool checks the original metadata, Organizer submission and exported App, preserves its bytes, links and permissions, signs only the new DMG, then mounts it read-only to verify its contents. It never builds or re-signs the App, submits notarization, modifies feeds, uploads assets or creates a Release. The resulting state is **signed, awaiting container notarization**, not ready for publication. Its preparation checksum describes the pre-stapling file.

Complete the separately authorized container notarization and stapling steps before publishing. Keep the submitted input unchanged and staple a separate copy; record the final container's checksum, signature and ticket checks. Test the Finder installation and launch experience separately from read-only mounting. If the DMG will also serve the updater, validate the actual old-version download, replacement and relaunch; a new version reporting “up to date” does not prove that upgrade path.

For a historical supplement, keep the original App, ZIP, signed feed, metadata and publication dates intact. Record the original source commit/version/Build and the newly created supplement's own preparation/publication date. Adding an installer does not retroactively make a local-only version a historically published release. Do not overwrite an existing asset or mark unperformed installation/update checks as passed.

## Durable records

Store each version/candidate outside Git and outside build caches. The default product archive root is `~/Library/Application Support/` followed by the product name and `ReleaseArchives/`. Maintain a version index.

Preserve the complete xcarchive, dSYMs and existing Submissions/Distributions, exported app, final container, source commit/version/Build mapping, public signing identity, notarization submission ID/status/full logs, checksums, release notes and any actual update manifest. See [software updates](updating.md) for preparing signed Sparkle archives and feeds from the Organizer-exported App. Archive the exact generated feed and ZIP; never regenerate or re-sign an already distributed App just to add update records.

Compare copied file content, symbolic-link targets and required permissions. Cache cleanup must not remove durable records. Do not store passwords, private keys, exported Keychains or account sessions.

Public notes state only actual verified results and use matching filenames/requirements. Public checksums contain filenames and hashes; private paths and full local logs stay in the authorized archive. First distribution guidance covers installation, startup, permissions and important limitations.
