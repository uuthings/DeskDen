#!/usr/bin/env python3
"""Fetch a pinned official Gitleaks build and verify it before execution."""
import hashlib
import os
from pathlib import Path
import platform
import subprocess
import sys
import tarfile
import tempfile
import urllib.request

VERSION = "8.30.1"
# SHA-256 digests published by the official gitleaks/gitleaks release API.
ARCHIVES = {
    ("Darwin", "arm64"): ("darwin_arm64", "b40ab0ae55c505963e365f271a8d3846efbc170aa17f2607f13df610a9aeb6a5"),
    ("Darwin", "x86_64"): ("darwin_x64", "dfe101a4db2255fc85120ac7f3d25e4342c3c20cf749f2c20a18081af1952709"),
    ("Linux", "aarch64"): ("linux_arm64", "e4a487ee7ccd7d3a7f7ec08657610aa3606637dab924210b3aee62570fb4b080"),
    ("Linux", "x86_64"): ("linux_x64", "551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb"),
}


def main():
    key = (platform.system(), platform.machine())
    if key not in ARCHIVES:
        raise SystemExit("No pinned Gitleaks binary for this platform")
    suffix, digest = ARCHIVES[key]
    base = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache"))
    cache = base / "deskden-tools" / "gitleaks" / VERSION / suffix
    cache.mkdir(parents=True, exist_ok=True)
    archive = cache / "release.tar.gz"
    executable = cache / "gitleaks"
    if not archive.is_file() or hashlib.sha256(archive.read_bytes()).hexdigest() != digest:
        url = f"https://github.com/gitleaks/gitleaks/releases/download/v{VERSION}/gitleaks_{VERSION}_{suffix}.tar.gz"
        with urllib.request.urlopen(url, timeout=60) as response:
            data = response.read(32 * 1024 * 1024)
        if hashlib.sha256(data).hexdigest() != digest:
            raise SystemExit("Official Gitleaks archive checksum mismatch")
        with tempfile.NamedTemporaryFile(dir=cache, delete=False) as handle:
            handle.write(data)
            temporary = Path(handle.name)
        temporary.replace(archive)
    with tarfile.open(archive, "r:gz") as bundle:
        member = next((item for item in bundle.getmembers() if item.name == "gitleaks" and item.isfile()), None)
        if member is None:
            raise SystemExit("Gitleaks executable missing from verified archive")
        data = bundle.extractfile(member).read()
    if not executable.is_file() or executable.read_bytes() != data:
        executable.write_bytes(data)
        executable.chmod(0o755)
    actual = subprocess.check_output([str(executable), "version"], text=True).strip()
    if actual != VERSION:
        raise SystemExit("Pinned Gitleaks version mismatch")
    print(executable)


if __name__ == "__main__":
    main()
