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

## Engineering names and distribution

Current source uses `DeskDen.xcodeproj`, scheme `DeskDen`, module and executable `DeskDenLauncher`, Bundle ID `local.deskden.launcher`, and native messaging host `com.uuthings.deskden.iproyal`. Current settings and data use the DeskDen namespace. The extension public identity key and the existing update signing key are independent of these names and must not be regenerated during a rename.

Each Release has one canonical DMG, an optional same-brand update ZIP, and one `SHA256SUMS.txt` covering all binary downloads. Do not keep duplicate spelling aliases or split checksum lists by packaging step. A documented optional connector must have a generic downloadable package named `DeskDen-IPRoyal-Connector-<version>-chrome-macos.zip`; its independent version uses three components.

Keep the source for the connector in the repository. Its downloadable package contains only generic files; local registration paths and account data are created on the installing computer. Historical signed Apps and source tags retain their original provenance. Changing an outer download filename does not rebuild or re-sign its contents. Before changing an update URL, re-sign and verify the feed and inspect every active download reference.

## Public release text

Lead with what the version does or changes, followed by necessary upgrade actions and concise download instructions. Use the correct version's installer and requirements. Keep data-format limitations and required backups understandable and visible.

Keep packaging chronology, local delivery history, authorization records, Organizer receipts, source-to-artifact audits and test logs in the private release archive. They are not release announcements. Release dates remain the actual hosting-platform dates; explaining internal bookkeeping is unnecessary.

Before publishing, review the rendered Release and product page, not only the source text. Verify the title, icon, connector name, recommended DMG, checksum link, installation guide and existing update compatibility. Run:

```sh
python3 tools/check-public-branding.py
python3 tools/check-public-branding.py --release-json "$RELEASE_JSON"
python3 tools/check-public-branding.py --release-json "$RELEASE_JSON" --checksums "$CHECKSUM_FILE"
```

The optional JSON is a GitHub Release-shaped object with `tag_name`, `name`, `body` and `assets`. For a prepared release, list the exact intended filenames. Repeat against the actual response after publication. The check validates copy and naming; it does not prove that files were uploaded, signed or downloaded correctly.
