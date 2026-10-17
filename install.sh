#!/bin/sh
# NetworkLuki APT repository installer for Debian.
# Usage: sudo sh install.sh
set -eu
umask 077

REPO_URL='https://pkgs.networkluki.com'
KEY_URL="$REPO_URL/pkgs.networkluki.com-archive.asc"
KEYRING='/etc/apt/keyrings/pkgs.networkluki.com.gpg'
LIST_FILE='/etc/apt/sources.list.d/pkgs.networkluki.com.list'

info() { printf '[NetworkLuki APT] %s\n' "$*"; }
fail() { printf '[NetworkLuki APT] ERROR: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || fail "Missing command: $1"; }

[ "$(id -u)" -eq 0 ] || fail 'Run as root: sudo sh install.sh'
[ -r /etc/os-release ] || fail 'Cannot detect operating system.'
. /etc/os-release
[ "${ID:-}" = 'debian' ] || fail 'Only Debian is supported. Ubuntu and derivatives are not automatically mapped to Debian releases.'
CODENAME=${VERSION_CODENAME:-}
case "$CODENAME" in
    trixie|bookworm|bullseye) ;;
    *) fail "Unsupported Debian codename: ${CODENAME:-unknown}. No automatic fallback is allowed." ;;
esac

need curl
need dpkg
need apt-get
need install
need mktemp
ARCH=$(dpkg --print-architecture)
case "$ARCH" in
    amd64|arm64|armhf) ;;
    *) fail "Unsupported architecture: $ARCH" ;;
esac

TMP_DIR=$(mktemp -d) || fail 'Could not create a temporary directory.'
trap 'rm -rf "$TMP_DIR"' 0
trap 'exit 1' 1 2 3 15

info "Checking $CODENAME ($ARCH) repository..."
# Require HTTPS on both initial requests and any redirects.
curl -fsSL --proto '=https' --proto-redir '=https' --connect-timeout 10 --max-time 60 --retry 2 \
    -o "$TMP_DIR/InRelease" "$REPO_URL/dists/$CODENAME/InRelease" \
    || fail "Signed repository metadata is unavailable for $CODENAME. No APT configuration was changed."
curl -fsSL --proto '=https' --proto-redir '=https' --connect-timeout 10 --max-time 60 --retry 2 \
    -o "$TMP_DIR/archive.asc" "$KEY_URL" \
    || fail 'Repository signing key is unavailable. No APT configuration was changed.'

if ! command -v gpg >/dev/null 2>&1; then
    info 'Installing GnuPG from the existing APT sources...'
    apt-get update || fail 'Unable to update existing APT sources.'
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends gnupg \
        || fail 'Unable to install GnuPG.'
fi
need gpgv

gpg --batch --no-tty --yes --dearmor --output "$TMP_DIR/archive.gpg" "$TMP_DIR/archive.asc" \
    || fail 'Invalid signing key.'
gpgv --keyring "$TMP_DIR/archive.gpg" "$TMP_DIR/InRelease" \
    || fail 'The repository metadata signature did not verify. No APT configuration was changed.'

# Debian architecture-specific sources avoid fetching unsupported architectures.
printf 'deb [arch=%s signed-by=%s] %s %s main\n' \
    "$ARCH" "$KEYRING" "$REPO_URL" "$CODENAME" > "$TMP_DIR/source.list"

install -d -m 0755 /etc/apt/keyrings /etc/apt/sources.list.d
[ ! -L "$KEYRING" ] || fail "Refusing to overwrite a symlink: $KEYRING"
[ ! -L "$LIST_FILE" ] || fail "Refusing to overwrite a symlink: $LIST_FILE"

# Preserve changed local configuration before replacement.
if [ -f "$LIST_FILE" ] && ! cmp -s "$LIST_FILE" "$TMP_DIR/source.list"; then
    BACKUP="${LIST_FILE}.bak.$(date -u +%Y%m%dT%H%M%SZ)"
    cp -p "$LIST_FILE" "$BACKUP" || fail 'Could not back up existing APT source.'
    info "Backed up previous source to $BACKUP"
fi

install -m 0644 "$TMP_DIR/archive.gpg" "$KEYRING" || fail 'Failed to install the signing key.'
install -m 0644 "$TMP_DIR/source.list" "$LIST_FILE" || fail 'Failed to install APT source.'

info "Installed $REPO_URL for Debian $CODENAME ($ARCH)."
info 'Run: sudo apt update'
info 'Then: sudo apt install <package-name>'
