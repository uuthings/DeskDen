# Product naming and release copy

The English product name is **DeskDen**; the Chinese app name is **方寸**.

| Surface | Name |
| --- | --- |
| Repository and English product pages | DeskDen |
| GitHub Release title | `DeskDen v<version>` |
| New macOS installer | `DeskDen-<version>-macos-universal.dmg` |
| New optional update ZIP | `DeskDen-<version>-macos-universal.zip` |
| Chrome extension, popup and native-host description | DeskDen IPRoyal Connector |
| Newly exported connection folder | `DeskDen-IPRoyal-Connector` |
| Chinese application UI and existing App bundle | 方寸 / 方寸.app |

Use the approved Desk artwork from `Launcher/Artwork/AppIcons/Desk` for product branding. The extension has dedicated small-size derivatives. Do not replace the app icon with a letter, Chinese-character tile or a different background.

## Compatibility

Keep installed identities separate from public display names. The existing Bundle ID, Keychain services, data directories, native messaging host `com.uuthings.fangcun.iproyal`, extension ID/key, project/scheme/module names and signed update addresses remain stable. Existing installed connection folders may retain their original paths. Renaming the extension must not reset its permissions or saved connection state.

Published installers, checksums, source tags, signatures and archive records are immutable. When a public download filename needs correction, add a byte-identical DeskDen-named download and a matching checksum file, then point current download instructions at it. Keep old download addresses that may already be in use. Do not rebuild or re-sign an old App to change its name.

## Public release text

Lead with what the version does or changes, followed by necessary upgrade actions and concise download instructions. Use the correct version's installer and requirements. Keep data-format limitations and required backups understandable and visible.

Keep packaging chronology, local delivery history, authorization records, Organizer receipts, source-to-artifact audits and test logs in the private release archive. They are not release announcements. Release dates remain the actual hosting-platform dates; explaining internal bookkeeping is unnecessary.

Before publishing, review the rendered Release and product page, not only the source text. Verify the title, icon, connector name, recommended DMG, checksum link, installation guide and existing update compatibility. Run:

```sh
python3 tools/check-public-branding.py
python3 tools/check-public-branding.py --release-json "$RELEASE_JSON"
```

The optional JSON is a GitHub Release-shaped object with `tag_name`, `name`, `body` and `assets`. For a prepared release, list the exact intended filenames. Repeat against the actual response after publication. The check validates copy and naming; it does not prove that files were uploaded, signed or downloaded correctly.
