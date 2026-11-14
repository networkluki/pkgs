#!/usr/bin/env python3
"""Import the exact reviewed CyberLab release; never modify APT metadata."""

from __future__ import annotations

import hashlib
import os
from pathlib import Path
import subprocess
import tempfile
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
NAME = "networkluki-cyberlab_0.1.2_amd64.deb"
SHA256 = "856939a724f1e2542af9cf21596a96062f7d86162e323aacaf78bda72452b385"
SIZE = 31177088
URL = f"https://github.com/networkluki/networkluki-cyberlab/releases/download/v0.1.2/{NAME}"


def verify(path: Path) -> None:
    if path.is_symlink() or not path.is_file() or path.stat().st_size != SIZE:
        raise ValueError("Unexpected CyberLab artifact type or size")
    with path.open("rb") as stream:
        actual = hashlib.file_digest(stream, "sha256").hexdigest()
    if actual != SHA256:
        raise ValueError("CyberLab release SHA-256 mismatch")
    for field, expected in (("Package", "networkluki-cyberlab"), ("Version", "0.1.2"), ("Architecture", "amd64")):
        actual = subprocess.check_output(["dpkg-deb", "--field", str(path), field], text=True, timeout=30).strip()
        if actual != expected:
            raise ValueError(f"Unexpected package {field}")


def main() -> None:
    destination = ROOT / "pool" / "main" / "n" / "networkluki-cyberlab" / NAME
    for parent in destination.parents:
        if parent == ROOT:
            break
        if parent.is_symlink():
            raise ValueError("Package directory cannot be a symbolic link")
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.exists() or destination.is_symlink():
        verify(destination)
        print(f"Already verified: {destination.relative_to(ROOT)}")
        return
    # Stage on the destination filesystem; hard-link publication never overwrites.
    with tempfile.TemporaryDirectory(prefix=".cyberlab-import-", dir=destination.parent) as temporary:
        download = Path(temporary) / NAME
        with urllib.request.urlopen(URL, timeout=60) as response, download.open("xb") as output:
            if not response.url.startswith("https://"):
                raise ValueError("Artifact redirect must use HTTPS")
            total = 0
            while chunk := response.read(1024 * 1024):
                total += len(chunk)
                if total > SIZE:
                    raise ValueError("Artifact exceeds its reviewed size")
                output.write(chunk)
            output.flush()
            os.fsync(output.fileno())
        verify(download)
        download.chmod(0o644)
        os.link(download, destination)
    print(f"Imported verified release: {destination.relative_to(ROOT)}")
    print("APT publication still requires the existing archive signing key.")


if __name__ == "__main__":
    main()
