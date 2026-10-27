# Public source scope

Keep buildable native source, tests, required tools, current production resources, accepted icon SVG and PNG sources and their conversion tools, and useful user/developer documentation.

The Desk icon suite has an exact file scope: `app-master.svg`, `app-small.svg`, the 16/18/20 menu templates, the named panel/small/menu PNGs and the ten standard `desk.iconset` PNG slots under `Launcher/Artwork/AppIcons/Desk/`; `provenance-desk.json` records the sources and derivation. Runtime resources are limited to `desk.icns`, `desk-small.png`, `desk-small-1x.png`, `desk-menubar.png` and `desk-menubar-1x.png`. This does not allow other SVGs, alternate icon sizes, design boards, comparison drafts or arbitrary files in the artwork directory.

Historical design exploration, authorization or collaboration diaries, real account screenshots, old apps, test deliverables, build caches and machine configuration stay outside the public index. Ignoring them does not delete local files. Public builds and verification do not require private archives.

The IPRoyal browser connector has an exact source-only scope under `Launcher/BrowserConnectors/IPRoyal`: its manifest and public extension identity, named JavaScript/HTML/CSS files, installer and export script, README, two named protocol tests, and exactly four flat icon files: `icon-16.png`, `icon-32.png`, `icon-64.png` and `icon-128.png`. These icons are byte-for-byte copies of the approved Desk assets: the 16 and 128 pixel slots in `Launcher/Artwork/AppIcons/Desk/desk.iconset/`, and `Launcher/Resources/AppIcons/desk-small-1x.png` (32 pixels) and `desk-small.png` (64 pixels). No other connector images, sizes, icon subdirectories or design drafts are allowed. The connector is maintained in the application repository and exported from the App as an optional connection kit. Exported connection kits, Native Messaging registrations, browser profiles, captured account responses and local mailbox files are never public inputs. The manifest key identifies the extension; it is a public key, not a service credential.

`tools/check-public-scope.py` enforces a path allowlist, file types, size limits, regular-file modes, private home-path and key checks, and pinned Gitleaks scanning. Image and policy changes also need visual and metadata review; text scanning cannot inspect pixels.

`tools/ensure-gitleaks.py` pins Gitleaks 8.30.1, downloads from its [official release](https://github.com/gitleaks/gitleaks/releases/tag/v8.30.1), and checks the pinned SHA-256 before executing it. The cache stays outside this repository. Download, version and scanner failures fail the gate.

The pre-commit gate checks the complete actual Git index. Commit titles use English Conventional Commits. Existing configured Git identities are preserved and examined with commit metadata during history review; the tools do not change them. The pre-push gate checks all ancestors of every proposed ref, including ancestors introduced by merges or tags. CI is an additional check. Local hooks must be installed and can still be bypassed by an authorized operator; CI cannot prevent an initial transmission.

These checks do not prove that information has never leaked. Passwords, private keys, exported keychains, account sessions and private raw distribution logs must not be committed.

Only the maintainer submits to this repository; Pull Requests are disabled. Issues remain available for feedback. Source browsing, cloning and platform fork settings are managed independently. No open-source license has been selected.
