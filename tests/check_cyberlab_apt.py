#!/usr/bin/env python3
"""Exercise the signed CyberLab APT preview on a disposable Debian 13 CI runner."""

from __future__ import annotations

from contextlib import contextmanager
import gzip
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
PACKAGE = "networkluki-cyberlab"
VERSION = "0.1.2"
FILENAME = f"{PACKAGE}_{VERSION}_amd64.deb"
SHA256 = "856939a724f1e2542af9cf21596a96062f7d86162e323aacaf78bda72452b385"
CI_SOURCE = Path("/etc/apt/sources.list.d/cyberlab-ci.list")


def run(arguments: list[str], **kwargs) -> subprocess.CompletedProcess:
    print("Running:", subprocess.list2cmdline(arguments), flush=True)
    return subprocess.run(arguments, check=True, timeout=180, **kwargs)


def digest(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def snapshot(directory: Path) -> dict[str, str]:
    return {str(path.relative_to(directory)): digest(path)
            for path in directory.rglob("*") if path.is_file()}


def paragraphs(text: str) -> list[dict[str, str]]:
    result = []
    for paragraph in text.strip().split("\n\n"):
        record: dict[str, str] = {}
        field = None
        for line in paragraph.splitlines():
            if line.startswith((" ", "\t")) and field is not None:
                record[field] += "\n" + line.strip()
            else:
                field, separator, value = line.partition(":")
                if not separator or field in record:
                    raise RuntimeError("Malformed or duplicate package metadata field")
                record[field] = value.strip()
        result.append(record)
    return result


def verify_preview(preview: Path) -> None:
    distribution = preview / "dists" / "trixie"
    release = paragraphs((distribution / "Release").read_text(encoding="utf-8"))[0]
    if (release.get("Codename"), release.get("Architectures"), release.get("Components")) != ("trixie", "amd64", "main"):
        raise RuntimeError("Unexpected preview distribution metadata")
    expected_paths = {"main/binary-amd64/Packages", "main/binary-amd64/Packages.gz"}
    observed_paths = set()
    for line in release["SHA256"].splitlines():
        if not line.strip():
            continue
        checksum, size, relative = line.split()
        if relative not in expected_paths or relative in observed_paths:
            raise RuntimeError("Unexpected or duplicate Release checksum path")
        observed_paths.add(relative)
        path = distribution / relative
        if path.stat().st_size != int(size) or digest(path) != checksum:
            raise RuntimeError(f"Release checksum mismatch: {relative}")
    if observed_paths != expected_paths:
        raise RuntimeError("Release omits an expected package index")
    index = distribution / "main" / "binary-amd64" / "Packages"
    if gzip.decompress(index.with_suffix(".gz").read_bytes()) != index.read_bytes():
        raise RuntimeError("Compressed package index differs from plain index")
    records = paragraphs(index.read_text(encoding="utf-8"))
    for record in records:
        relative = Path(record["Filename"])
        if relative.is_absolute() or ".." in relative.parts or relative.parts[:2] != ("pool", "main"):
            raise RuntimeError("Package index contains an unsafe payload path")
        payload = ROOT / relative
        if payload.stat().st_size != int(record["Size"]) or digest(payload) != record["SHA256"]:
            raise RuntimeError(f"Package payload checksum mismatch: {relative}")
    matches = [record for record in records if record.get("Package") == PACKAGE]
    if len(matches) != 1:
        raise RuntimeError("Preview must contain exactly one reviewed CyberLab package")
    package = matches[0]
    if (package.get("Version"), package.get("Architecture"), package.get("SHA256")) != (VERSION, "amd64", SHA256):
        raise RuntimeError("CyberLab metadata does not match the reviewed release")
    original = paragraphs((ROOT / "dists/trixie/main/binary-amd64/Packages").read_text(encoding="utf-8"))
    before = {(record["Package"], record["Version"], record["Architecture"], record["SHA256"]) for record in original}
    after = {(record["Package"], record["Version"], record["Architecture"], record["SHA256"]) for record in records}
    if not before.issubset(after):
        raise RuntimeError("Preview removed or changed an existing indexed package")


@contextmanager
def test_key_home(directory: Path):
    directory.mkdir(mode=0o700)
    try:
        yield directory
    finally:
        run(["gpgconf", "--homedir", str(directory), "--kill", "gpg-agent"])


def main() -> None:
    if os.environ.get("GITHUB_ACTIONS") != "true" or os.geteuid() != 0:
        raise SystemExit("This integration check requires a disposable root GitHub Actions container.")
    release = dict(line.split("=", 1) for line in Path("/etc/os-release").read_text().splitlines() if "=" in line)
    if release.get("ID", "").strip('"') != "debian" or release.get("VERSION_ID", "").strip('"') != "13":
        raise SystemExit("Run this check in the Debian 13 container used for publication validation.")
    if CI_SOURCE.exists() or CI_SOURCE.is_symlink():
        raise SystemExit("Refusing to replace an existing CI APT source.")
    before = snapshot(ROOT / "dists")
    run(["bash", str(ROOT / "scripts/publish-cyberlab.sh"), "--dry-run"], cwd=ROOT)
    if snapshot(ROOT / "dists") != before:
        raise RuntimeError("Dry-run modified the live signed distribution files")
    preview = ROOT / ".git" / "cyberlab-preview"
    verify_preview(preview)
    created_source = False
    with tempfile.TemporaryDirectory(prefix="cyberlab-apt-ci-", dir="/tmp") as temporary:
        temporary_root = Path(temporary)
        temporary_root.chmod(0o755)
        repository = temporary_root / "repository"
        shutil.copytree(preview / "dists", repository / "dists")
        shutil.copytree(ROOT / "pool", repository / "pool")
        for path in [repository, *repository.rglob("*")]:
            path.chmod(0o755 if path.is_dir() else 0o644)
        with test_key_home(temporary_root / "test-signing-key") as signing_home:
            gpg = ["gpg", "--homedir", str(signing_home), "--batch", "--pinentry-mode", "loopback", "--passphrase", ""]
            run([*gpg, "--quick-generate-key", "CyberLab CI fixture <ci@example.invalid>", "ed25519", "sign", "1d"])
            listing = run([*gpg, "--with-colons", "--list-keys"], capture_output=True, text=True).stdout
            fingerprints = [line.split(":")[9] for line in listing.splitlines() if line.startswith("fpr:")]
            if len(fingerprints) != 1:
                raise RuntimeError("Expected exactly one ephemeral test signing key")
            fingerprint = fingerprints[0]
            if fingerprint == "8292CD2CF489DFBF14954D2F1C3F89018DA4223D":
                raise RuntimeError("Test key must never be the production archive key")
            public_key = temporary_root / "test-archive.gpg"
            public_key.write_bytes(run([*gpg, "--export", fingerprint], capture_output=True).stdout)
            public_key.chmod(0o644)
            dist = repository / "dists" / "trixie"
            run([*gpg, "--local-user", fingerprint, "--clearsign", "--output", str(dist / "InRelease"), str(dist / "Release")])
            (dist / "InRelease").chmod(0o644)
            try:
                descriptor = os.open(CI_SOURCE, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644)
                created_source = True
                with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
                    stream.write(f"deb [arch=amd64 signed-by={public_key}] file://{repository} trixie main\n")
                CI_SOURCE.chmod(0o644)
                run(["apt-get", "--error-on=any", "update"])
                run(["apt-get", "--simulate", "install", f"{PACKAGE}={VERSION}"])
                downloaded = temporary_root / "download"
                downloaded.mkdir(mode=0o755)
                run(["apt-get", "download", f"{PACKAGE}={VERSION}"], cwd=downloaded)
                if digest(downloaded / FILENAME) != SHA256:
                    raise RuntimeError("APT downloaded unexpected CyberLab package bytes")
            finally:
                if created_source:
                    CI_SOURCE.unlink()
        if snapshot(ROOT / "dists") != before:
            raise RuntimeError("APT integration check changed production metadata")
        print(json.dumps({"ok": True, "distribution": "Debian 13", "package": PACKAGE,
                          "version": VERSION, "sha256": SHA256, "signed_apt_verified": True,
                          "dependency_resolution": True, "production_metadata_unchanged": True}), flush=True)


if __name__ == "__main__":
    main()
