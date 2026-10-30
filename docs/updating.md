# Software updates

DeskDen embeds the pinned Sparkle 2.10.0 framework in both the Xcode target and SwiftPM previews. Sparkle is distributed under its own license, retained inside the framework. Its source, signed distribution and documentation are maintained at [sparkle-project/Sparkle](https://github.com/sparkle-project/Sparkle).

Xcode's final build phase signs the embedded framework's four helpers inside-out with the expanded build identity before the App's final signature. Developer ID builds require the existing team, Hardened Runtime and secure timestamps; Debug uses ad-hoc signing, and unsigned CI skips this phase. Only Downloader preserves its own entitlements, following [Sparkle's signing instructions](https://sparkle-project.org/documentation/sandboxing/#code-signing); helpers never inherit the App's Keychain access. The script accepts only Xcode build/archive product context, does not touch the package cache or an Organizer export, and records verification in the derived build directory. Formal distribution still uses Archive → Organizer → exported notarized App; do not run this script on an exported App.

## User behavior

Settings → General contains **Check for Updates** and **Automatically check for updates**. The application and menu-bar menus also offer a manual check. New installations use manual mode: displaying settings or starting the app does not initiate an updater request or an automatic-check permission prompt. Automatic checks are opt-in, run on Sparkle's daily schedule and persist using Sparkle's own preference key. Automatic downloading/installing and system-profile reporting are disabled. Installation remains an explicit user choice.

The updater uses HTTPS, validates the signed feed and verifies the archive's Ed25519 signature before extraction. An Install & Relaunch request uses the same encrypted-write, editor-draft, cleaning-transaction and notification shutdown barriers as a normal quit. Cancelling a save decision prevents termination. Checking for updates does not itself quit the app or change local data.

Starting with 0.4.0, the embedded feed address is `https://updates.uuthings.com/deskden/macos/stable/appcast.xml`. New update archives use `https://updates.uuthings.com/deskden/macos/releases/<version>-<Build>/`. R2 is the primary download service; every formal installer and update archive must also be published to the matching GitHub Release with identical bytes, size and SHA-256. GitHub retains the historical downloads. The 0.4.0 migration uploads only 0.4.0 to R2; older signed entries keep their existing GitHub archive URLs.

Older Sparkle-enabled versions still request `https://raw.githubusercontent.com/uuthings/DeskDen/main/updates/appcast.xml`. Keep that endpoint as a byte-for-byte mirror of the same final signed feed on every release, including releases after 0.4.0. Changing the new App's address alone does not migrate installed copies. The GitHub mirror is an alternative manual download source, not an automatic updater failover. Never label a failed feed request as “up to date.” The original 0.1.0 builds without Sparkle need a one-time manual installation of a current release; later published versions can use the in-app updater. See the [installation and upgrade guide](install.md) before migrating an original-format Private Space.

## Signing material

The public Ed25519 key is in `SUPublicEDKey`. Its matching private key is stored only in the maintainer's login Keychain under its existing dedicated Sparkle account. Pass the existing account through `--signing-account` when preparing a feed; a source or Bundle ID rename does not change this signing key. It is separate from Apple Developer ID and is not exported into source, environment files, archives or CI. Reuse this key for subsequent updates; do not regenerate it per build. On another signing Mac, arrange an explicit secure key transfer before preparing updates. Do not place a private key in a GitHub secret merely to make an unauthorised workflow run.

## Prepare a future release without publishing

Follow [the Organizer release process](releasing.md) first. Export the notarized App from its real archive; do not re-sign it. Obtain the same official Sparkle distribution as the pinned package and verify its published checksum. Then prepare a new directory outside Git:

```sh
python3 tools/prepare-update-feed.py --app "$EXPORTED_NOTARIZED_APP" \
  --sparkle-bin "$VERIFIED_SPARKLE_BIN" --signing-account "$SPARKLE_SIGNING_ACCOUNT" --notes "$PUBLIC_RELEASE_NOTES" \
  --download-url-prefix "https://updates.uuthings.com/deskden/macos/releases/0.4.0-5/" \
  --output "$NEW_PERSISTENT_UPDATE_DIRECTORY"
```

The tool checks the exported App, notarization ticket, Gatekeeper acceptance and updater configuration. It packages the original exported App, uses the official `generate_appcast` tool to sign the ZIP and feed, verifies the feed, and records checksums. The download prefix defaults to the UUThings directory for the exported App's exact version and Build; an explicit prefix must match that directory or its corresponding DeskDen GitHub Release directory. It cannot target another application, arbitrary host or different release. It performs no upload, notarization submission, push, tag or Release. Retain these outputs with the complete Organizer archive and release records.

This tool intentionally remains the ZIP workflow used by existing published updates. It does not prepare the drag-install DMG described in [the release process](releasing.md#installers-and-update-artifacts). Sparkle can use a DMG for both manual installation and automatic updating, but switching a future release to that workflow requires packaging, signing and complete upgrade validation; it must not silently replace the existing ZIP or feed. A local `prepare-dmg.py` result still awaits separate container notarization and final-byte checks before it can become an update artifact.

The supplied notes are the in-app change summary: include meaningful changes and required upgrade actions, with a link to the full Release. Keep routine installation, signing and checksum instructions in the public Release or installation guide. A generated feed is an unpublished draft. Its generated date must not be presented as an authoritative publication time: before uploading the feed, use the actual Release `published_at` for the item date, or omit the date when it is unknown. Re-sign the resulting feed with the existing official `sign_update` tool, verify it, and refresh its checksum and preparation record before publication.

When publication is explicitly authorized, publish the same final DMG, update ZIP and checksum file to the immutable UUThings version/Build directory and the matching GitHub Release. Verify both downloads before publishing the final signed `appcast.xml` to the stable UUThings address and its legacy GitHub mirror; both feeds must contain identical bytes. Do not rewrite historical archive URLs or backfill old packages as part of this migration. Any feed or note change requires regenerated signatures and checksums. Verify both feed endpoints and archive bytes before advertising availability. Bump the next release's `CFBundleVersion` above every published build; Sparkle uses that field for update ordering.

See the official [programmatic setup](https://sparkle-project.org/documentation/programmatic-setup/) and [publishing guide](https://sparkle-project.org/documentation/publishing/).
