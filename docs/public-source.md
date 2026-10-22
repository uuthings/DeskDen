# Public source scope

Keep buildable native source, tests, required tools, current production resources, accepted icon PNG sources and their conversion tool, and useful user/developer documentation.

Historical design exploration, authorization or collaboration diaries, real account screenshots, old apps, test deliverables, build caches and machine configuration stay outside the public index. Ignoring them does not delete local files. Public builds and verification do not require private archives.

`tools/check-public-scope.py` enforces a path allowlist, file types, size limits, regular-file modes, private home-path and key checks, and pinned Gitleaks scanning. Image and policy changes also need visual and metadata review; text scanning cannot inspect pixels.

`tools/ensure-gitleaks.py` pins Gitleaks 8.30.1, downloads from its [official release](https://github.com/gitleaks/gitleaks/releases/tag/v8.30.1), and checks the pinned SHA-256 before executing it. The cache stays outside this repository. Download, version and scanner failures fail the gate.

The pre-commit gate checks the complete actual Git index. Commit titles use English Conventional Commits. Existing configured Git identities are preserved and examined with commit metadata during history review; the tools do not change them. The pre-push gate checks all ancestors of every proposed ref, including ancestors introduced by merges or tags. CI is an additional check. Local hooks must be installed and can still be bypassed by an authorized operator; CI cannot prevent an initial transmission.

These checks do not prove that information has never leaked. Passwords, private keys, exported keychains, account sessions and private raw distribution logs must not be committed.

Only the maintainer submits to this repository; Pull Requests are disabled. Issues remain available for feedback. Source browsing, cloning and platform fork settings are managed independently. No open-source license has been selected.
