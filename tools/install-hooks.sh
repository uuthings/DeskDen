#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
git config --local core.hooksPath .githooks
python3 tools/ensure-gitleaks.py >/dev/null
printf '%s\n' 'Public scope, commit-message and outgoing-history hooks installed.'
