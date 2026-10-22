# macOS release process

Version 0.1.0 (Build 2) was signed, notarized through Organizer and retained as a local delivery. It has not been publicly published. Later development changes are local test candidates until a new release is explicitly authorized. This document describes the required process; each candidate's own evidence establishes its actual result.

## Candidate and version

Finish changes and verification, set the source version and Build, and record the actual Git commit, Xcode/SDK versions and build arguments. Use a distinct directory for each candidate; retain old apps and designs. An ordinary commit does not authorize version changes, tags, pushes or Releases.

Reuse the existing Bundle ID, team and valid Developer ID. Signing keys stay in the local Keychain. Each new build needs signing and notarization; never re-sign an already notarized exported app.

Private Space's optional Touch ID requires an Apple-authorized provisioning profile for the existing app identifier and its own Keychain access group. Configure the matching app identifier, team identifier and Keychain group entitlements in the signed build, and embed the matching profile. Do not substitute an ad-hoc signature or an unprotected Keychain item. Local development builds without this authorization keep password unlock and explicitly report Touch ID as unavailable. Profiles, credentials and private keys are not source files.

## Archive and Organizer

1. Create a real `.xcarchive` with Xcode Archive or `xcodebuild archive`, under the default `~/Library/Developer/Xcode/Archives/`, and confirm that Organizer lists it.
2. Submit from Organizer using **Distribute App / Direct Distribution**, or **Developer ID / Upload**.
3. Wait for **Ready to distribute**, then export the notarized app from that same archive.
4. Check the exported app's signature, Developer ID, Hardened Runtime, architectures, ticket and Gatekeeper assessment before packaging.

Independent `notarytool submit` uploads of an App or ZIP do not replace Organizer distribution. If login, validation or notarization is blocked, retain the candidate/evidence and record the actual obstacle. Command-line status queries, log downloads and ticket/signature checks are allowed.

DMG/PKG signing and notarization have independent container records, which are not claimed as Organizer history. Generate checksums only after all packaging, signing and stapling changes; verify the final distributed bytes.

## Durable records

Store each version/candidate outside Git and outside build caches. The default product archive root is `~/Library/Application Support/` followed by the product name and `ReleaseArchives/`. Maintain a version index.

Preserve the complete xcarchive, dSYMs and existing Submissions/Distributions, exported app, final container, source commit/version/Build mapping, public signing identity, notarization submission ID/status/full logs, checksums, release notes and any actual update manifest. If there is no updater, record that fact rather than inventing a manifest.

Compare copied file content, symbolic-link targets and required permissions. Cache cleanup must not remove durable records. Do not store passwords, private keys, exported Keychains or account sessions.

Public notes state only actual verified results and use matching filenames/requirements. Public checksums contain filenames and hashes; private paths and full local logs stay in the authorized archive. First distribution guidance covers installation, startup, permissions and important limitations.
