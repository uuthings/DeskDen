# Software updates

Fangcun embeds the pinned Sparkle 2.10.0 framework in both the Xcode target and SwiftPM previews. Sparkle is distributed under its own license, retained inside the framework. Its source, signed distribution and documentation are maintained at [sparkle-project/Sparkle](https://github.com/sparkle-project/Sparkle).

Xcode's final build phase signs the embedded framework's four helpers inside-out with the expanded build identity before the App's final signature. Developer ID builds require the existing team, Hardened Runtime and secure timestamps; Debug uses ad-hoc signing, and unsigned CI skips this phase. Only Downloader preserves its own entitlements, following [Sparkle's signing instructions](https://sparkle-project.org/documentation/sandboxing/#code-signing); helpers never inherit the App's Keychain access. The script accepts only Xcode build/archive product context, does not touch the package cache or an Organizer export, and records verification in the derived build directory. Formal distribution still uses Archive → Organizer → exported notarized App; do not run this script on an exported App.

## User behavior

Settings → General contains **Check for Updates** and **Automatically check for updates**. The application and menu-bar menus also offer a manual check. New installations use manual mode: displaying settings or starting the app does not initiate an updater request or an automatic-check permission prompt. Automatic checks are opt-in, run on Sparkle's daily schedule and persist using Sparkle's own preference key. Automatic downloading/installing and system-profile reporting are disabled. Installation remains an explicit user choice.

The updater uses HTTPS, validates the signed feed and verifies the archive's Ed25519 signature before extraction. An Install & Relaunch request uses the same encrypted-write, editor-draft, cleaning-transaction and notification shutdown barriers as a normal quit. Cancelling a save decision prevents termination. Checking for updates does not itself quit the app or change local data.

The feed address is `https://raw.githubusercontent.com/uuthings/DeskDen/main/updates/appcast.xml`. It lists the published, signed updates and their matching GitHub Release assets. Never label a failed feed request as “up to date.” The original 0.1.0 builds without Sparkle need a one-time manual installation of a current release; later published versions can use the in-app updater. See the [installation and upgrade guide](install.md) before migrating an original-format Private Space.

## Signing material

The public Ed25519 key is in `SUPublicEDKey`. Its matching private key is stored only in the maintainer's login Keychain under the dedicated Sparkle account `local.fangcun.launcher`. It is separate from Apple Developer ID and is not exported into source, environment files, archives or CI. Reuse this key for subsequent updates; do not regenerate it per build. On another signing Mac, arrange an explicit secure key transfer before preparing updates. Do not place a private key in a GitHub secret merely to make an unauthorised workflow run.

## Prepare a future release without publishing

Follow [the Organizer release process](releasing.md) first. Export the notarized App from its real archive; do not re-sign it. Obtain the same official Sparkle distribution as the pinned package and verify its published checksum. Then prepare a new directory outside Git:

```sh
python3 tools/prepare-update-feed.py --app "$EXPORTED_NOTARIZED_APP" \
  --sparkle-bin "$VERIFIED_SPARKLE_BIN" --notes "$PUBLIC_RELEASE_NOTES" \
  --output "$NEW_PERSISTENT_UPDATE_DIRECTORY"
```

The tool checks the exported App, notarization ticket, Gatekeeper acceptance and updater configuration. It packages the original exported App, uses the official `generate_appcast` tool to sign the ZIP and feed, verifies the feed, and records checksums. It performs no upload, notarization submission, push, tag or Release. Retain these outputs with the complete Organizer archive and release records.

The supplied notes are the in-app change summary: include meaningful changes and required upgrade actions, with a link to the full Release. Keep routine installation, signing and checksum instructions in the public Release or installation guide. A generated feed is an unpublished draft. Its generated date must not be presented as an authoritative publication time: before uploading the feed, use the actual Release `published_at` for the item date, or omit the date when it is unknown. Re-sign the resulting feed with the existing official `sign_update` tool, verify it, and refresh its checksum and preparation record before publication.

When publication is explicitly authorized, upload the exact ZIP to its matching GitHub Release and publish the final signed `appcast.xml` at the configured address. Any feed or note change requires regenerated signatures and checksums. Verify the online feed and archive bytes before advertising availability. Bump the next release's `CFBundleVersion` above every published build; Sparkle uses that field for update ordering.

See the official [programmatic setup](https://sparkle-project.org/documentation/programmatic-setup/) and [publishing guide](https://sparkle-project.org/documentation/publishing/).
