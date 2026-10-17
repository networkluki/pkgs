#!/usr/bin/env bash
# Build and sign an APT repository for Ubuntu 26.04 (resolute).
# Run on the trusted machine that owns the archive signing key.
set -euo pipefail
umask 077

readonly EXPECTED_FPR='8292CD2CF489DFBF14954D2F1C3F89018DA4223D'
readonly CODENAME='resolute'
readonly ARCH='amd64'
readonly REPO_DOMAIN='pkgs.networkluki.com'

info() { printf '[NetworkLuki APT] %s\n' "$*"; }
fail() { printf '[NetworkLuki APT] ERROR: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || fail "Missing command: $1"; }

for cmd in git dpkg-deb apt-ftparchive gzip gpg mktemp install grep; do
  need "$cmd"
done

[[ "$(id -u)" -ne 0 ]] || fail 'Sign as your normal user, never as root.'

readonly ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
[[ -d .git ]] || fail 'Run this script from a local Git clone of the repository.'
[[ -r CNAME ]] || fail 'CNAME is missing.'
[[ "$(cat CNAME)" == "$REPO_DOMAIN" ]] || fail 'Unexpected repository CNAME.'

readonly PACKAGE_DIR='pool/main/t/tictactoe'
readonly EXPECTED_PACKAGE="$PACKAGE_DIR/tictactoe_1.1.0_all.deb"
readonly DIST_DIR="dists/$CODENAME"
[[ -f "$EXPECTED_PACKAGE" && ! -L "$EXPECTED_PACKAGE" ]] || fail 'Expected Tic-Tac-Toe 1.1.0 package missing or symlinked.'
[[ ! -e "$DIST_DIR" && ! -L "$DIST_DIR" ]] || fail "$DIST_DIR already exists; review and update it manually instead of overwriting."

# Refuse to sign dirty/modified package files.
[[ -z "$(git status --porcelain -- "$PACKAGE_DIR")" ]] || fail 'Uncommitted package changes detected; review them before signing.'

# Only index reviewed all-architecture Tic-Tac-Toe packages.
shopt -s nullglob
packages=("$PACKAGE_DIR"/*.deb)
((${#packages[@]} > 0)) || fail 'No DEB packages found.'
for package in "${packages[@]}"; do
  [[ -f "$package" && ! -L "$package" ]] || fail "Unexpected package file: $package"
  [[ "$(dpkg-deb -f "$package" Package)" == 'tictactoe' ]] || fail "Unexpected package name: $package"
  [[ "$(dpkg-deb -f "$package" Architecture)" == 'all' ]] || fail "Package is not architecture-independent: $package"
  info "Verified package metadata: $package"
done
[[ "$(dpkg-deb -f "$EXPECTED_PACKAGE" Version)" == '1.1.0' ]] || fail 'Unexpected Tic-Tac-Toe version.'

# Verify that the expected signing key is actually available locally.
if ! gpg --batch --with-colons --list-secret-keys "$EXPECTED_FPR" \
  | grep -Fq "fpr:::::::::$EXPECTED_FPR:"; then
  fail "GPG secret key $EXPECTED_FPR not available."
fi

TEMP_DIR="$(mktemp -d)" || fail 'Cannot create temporary directory.'
readonly TEMP_DIR
trap 'rm -rf -- "$TEMP_DIR"' EXIT
readonly STAGE="$TEMP_DIR/$CODENAME"
mkdir -p "$STAGE/main/binary-$ARCH"

# Include archived versions; APT will choose the highest valid version.
apt-ftparchive --arch "$ARCH" packages "$PACKAGE_DIR" > "$STAGE/main/binary-$ARCH/Packages"
[[ -s "$STAGE/main/binary-$ARCH/Packages" ]] || fail 'Generated Packages index is empty.'
gzip -9 -n -c "$STAGE/main/binary-$ARCH/Packages" > "$STAGE/main/binary-$ARCH/Packages.gz"

apt-ftparchive \
  -o "APT::FTPArchive::Release::Origin=NetworkLuki" \
  -o "APT::FTPArchive::Release::Label=NetworkLuki Packages" \
  -o "APT::FTPArchive::Release::Suite=$CODENAME" \
  -o "APT::FTPArchive::Release::Codename=$CODENAME" \
  -o "APT::FTPArchive::Release::Architectures=$ARCH" \
  -o 'APT::FTPArchive::Release::Components=main' \
  release "$STAGE" > "$STAGE/Release"

# Signing is interactive when the private key has a passphrase.
gpg --local-user "$EXPECTED_FPR" --yes --clearsign \
  --output "$STAGE/InRelease" "$STAGE/Release"
gpg --local-user "$EXPECTED_FPR" --yes --armor --detach-sign \
  --output "$STAGE/Release.gpg" "$STAGE/Release"

gpg --verify "$STAGE/InRelease"
gpg --verify "$STAGE/Release.gpg" "$STAGE/Release"

install -d -m 0755 "$DIST_DIR/main/binary-$ARCH"
for file in Release InRelease Release.gpg; do
  install -m 0644 "$STAGE/$file" "$DIST_DIR/$file"
done
for file in Packages Packages.gz; do
  install -m 0644 "$STAGE/main/binary-$ARCH/$file" "$DIST_DIR/main/binary-$ARCH/$file"
done

info "Signed Ubuntu $CODENAME ($ARCH) metadata created in $DIST_DIR"
info 'Review: git status --short -- dists/resolute'
info 'Review: cat dists/resolute/Release'
info 'Review: cat dists/resolute/main/binary-amd64/Packages'
info 'Once approved: git add dists/resolute && git commit -m "Publish signed Ubuntu Resolute APT repository" && git push origin main'
