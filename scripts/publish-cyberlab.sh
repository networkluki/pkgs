#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# NAME        : publish-cyberlab.sh
# PURPOSE     : Stage or locally sign CyberLab 0.1.2 for Debian 13 amd64.
# USAGE       : bash scripts/publish-cyberlab.sh [--dry-run|--commit]
# DEPENDENCIES: Bash 5.2+, GNU coreutils, git, apt-utils, gnupg, python3, flock
# EXIT CODES  : 0 success | 1 error | 2 usage | 3 another publisher holds lock
# VERSION     : 1.0.0
# CHANGELOG   : 1.0.0 initial; never uploads files or exports signing keys
# ---------------------------------------------------------------------------
set -Eeuo pipefail
IFS=$'\n\t'
PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'
export PATH
umask 077

readonly SCRIPT_NAME="${BASH_SOURCE[0]##*/}"
readonly EXPECTED_FPR='8292CD2CF489DFBF14954D2F1C3F89018DA4223D'
readonly PACKAGE='pool/main/n/networkluki-cyberlab/networkluki-cyberlab_0.1.2_amd64.deb'
readonly PACKAGE_SHA='856939a724f1e2542af9cf21596a96062f7d86162e323aacaf78bda72452b385'
readonly DIST='dists/trixie'
readonly FILES=('main/binary-amd64/Packages' 'main/binary-amd64/Packages.gz' 'Release' 'Release.gpg' 'InRelease')
ROOT_DIR=''; WORK=''; BACKUP=''; REPLACING=0; FINISHED=0

log() { printf '%s [%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "${*:2}" >&2; }
die() { log ERROR "$*"; exit 1; }
usage() { printf 'Usage: %s [--dry-run|--commit]\n' "$SCRIPT_NAME" >&2; }
atomic_copy() {
  local source="$1" destination="$2" temporary
  temporary="$(mktemp -- "${destination}.cyberlab.XXXXXX")"
  if ! install -m 0644 -- "$source" "$temporary" || ! mv -fT -- "$temporary" "$destination"; then
    rm -f -- "$temporary"
    return 1
  fi
}
cleanup() {
  local status=$? file resolved
  trap - EXIT ERR INT TERM HUP
  if [[ "$REPLACING" == 1 && "$FINISHED" == 0 ]]; then
    log ERROR "Restoring previous metadata from $BACKUP"
    for file in "${FILES[@]}"; do
      atomic_copy "$BACKUP/$file" "$ROOT_DIR/$DIST/$file" || log ERROR "Restore failed: $file; use retained backup."
    done
  fi
  if [[ -n "$WORK" && -d "$WORK" && ! -L "$WORK" ]]; then
    resolved="$(realpath -e -- "$WORK")"
    if [[ "$resolved" == "$ROOT_DIR/.git/cyberlab-work."* ]]; then rm -rf -- "$resolved"; fi
  fi
  exit "$status"
}
trap cleanup EXIT
trap 'log ERROR "Failed at line $LINENO"' ERR
trap 'exit 130' INT TERM HUP

validate_metadata() {
  python3 - "$ROOT_DIR" "$1" "$2" "$PACKAGE" "$PACKAGE_SHA" <<'PY'
import gzip, hashlib, pathlib, subprocess, sys
root, dist, baseline = map(pathlib.Path, sys.argv[1:4])
expected_file, expected_sha = sys.argv[4:6]
def require(ok, message):
    if not ok: raise SystemExit(message)
def safe_file(path):
    require(path.is_relative_to(root), 'Path outside checkout')
    require(all(not p.is_symlink() for p in (path, *path.parents) if p.is_relative_to(root)), 'Symlink in repository path')
    require(path.is_file(), 'Expected ordinary file: ' + str(path))
    return path.read_bytes()
def records(data):
    result=[]
    for block in data.decode('utf-8').strip().split('\n\n'):
        record={}; key=None
        for line in block.splitlines():
            if line.startswith((' ', '\t')):
                require(key is not None, 'Malformed continuation')
                record[key]+='\n'+line
            else:
                key, sep, value=line.partition(':')
                require(sep and key not in record, 'Malformed or duplicate field')
                record[key]=value.lstrip()
        result.append(record)
    return result
release=records(safe_file(dist/'Release'))[0]
for key,value in {'Codename':'trixie','Suite':'trixie','Components':'main','Architectures':'amd64','Origin':'NetworkLuki'}.items():
    require(release.get(key)==value, 'Unexpected Release field: '+key)
indexes={}
for line in release.get('SHA256','').splitlines():
    if not line.strip(): continue
    digest,size,name=line.split()
    require(name in ('main/binary-amd64/Packages','main/binary-amd64/Packages.gz') and name not in indexes, 'Unexpected Release index')
    data=safe_file(dist/name)
    require(len(data)==int(size) and hashlib.sha256(data).hexdigest()==digest, 'Release hash mismatch: '+name)
    indexes[name]=data
require(len(indexes)==2, 'Missing Release indexes')
plain=indexes['main/binary-amd64/Packages']
require(gzip.decompress(indexes['main/binary-amd64/Packages.gz'])==plain, 'Compressed index differs')
packages={}
for item in records(plain):
    name=item.get('Filename','')
    require(name.startswith('pool/main/') and '\n' not in name and '..' not in pathlib.PurePosixPath(name).parts, 'Unsafe package filename')
    require(name not in packages, 'Duplicate package filename')
    data=safe_file(root/name)
    require(len(data)==int(item['Size']) and hashlib.sha256(data).hexdigest()==item['SHA256'], 'Package hash mismatch: '+name)
    for field in ('Package','Version','Architecture'):
        actual=subprocess.check_output(['dpkg-deb','-f',str(root/name),field],text=True).strip()
        require(actual==item[field], 'Package control mismatch: '+field)
    require((item['Package']=='tictactoe' and item['Architecture']=='all') or
            (name==expected_file and item['Package']=='networkluki-cyberlab' and item['Version']=='0.1.2' and item['Architecture']=='amd64'), 'Unreviewed package in index')
    if name==expected_file: require(item['SHA256']==expected_sha and len(data)==31177088, 'Unexpected CyberLab binary')
    packages[name]=item
if dist!=baseline:
    old={item['Filename']:item for item in records(safe_file(baseline/'main/binary-amd64/Packages'))}
    require(set(packages)==set(old)|{expected_file}, 'Existing package set changed')
    for name,item in old.items(): require(packages[name]==item, 'Existing package metadata changed: '+name)
    require(expected_file in packages, 'CyberLab missing from staged index')
print(f'Validated {len(packages)} package records in {dist.relative_to(root)}')
PY
}

verify_signatures() {
  local directory="$1"
  gpg --no-options --homedir "$WORK/keyring" --batch --verify "$directory/Release.gpg" "$directory/Release"
  gpg --no-options --homedir "$WORK/keyring" --batch --output "$WORK/verified-release" --yes --decrypt "$directory/InRelease"
  cmp -- "$WORK/verified-release" "$directory/Release" || die 'InRelease and Release differ.'
}

main() {
  local mode='--dry-run' command fingerprint stage file preview
  if (($# > 1)); then usage; exit 2; fi
  if (($# == 1)); then mode="$1"; fi
  case "$mode" in --dry-run|--commit) ;; --help|-h) usage; return 0 ;; *) usage; exit 2 ;; esac
  for command in git dpkg-deb apt-ftparchive gzip gpg python3 flock mktemp install realpath mv rm cp cmp awk date id mkdir dirname; do
    command -v "$command" >/dev/null 2>&1 || die "Missing command: $command"
  done
  ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
  cd -- "$ROOT_DIR"
  [[ -d .git && ! -L .git ]] || die 'Use a normal local Git clone.'
  [[ "$(git rev-parse --show-toplevel)" == "$ROOT_DIR" ]] || die 'Unexpected Git root.'
  [[ -f CNAME && ! -L CNAME && "$(< CNAME)" == 'pkgs.networkluki.com' ]] || die 'Unexpected repository domain.'
  [[ ! -L .git/cyberlab-publish.lock ]] || die 'Symlinked lock path.'
  exec 9> .git/cyberlab-publish.lock
  flock -n 9 || { log INFO 'Another publisher holds the lock.'; exit 3; }
  if [[ "$mode" == '--commit' ]]; then
    [[ "$(id -u)" -ne 0 ]] || die 'Sign as your normal user, never as root.'
    [[ -z "$(git status --porcelain -- pool dists/trixie pkgs.networkluki.com-archive.asc)" ]] || die 'Commit reviewed pool/key/index changes before signing.'
  fi
  WORK="$(mktemp -d -- "$ROOT_DIR/.git/cyberlab-work.XXXXXX")"
  mkdir -m 0700 -- "$WORK/keyring"
  [[ -f pkgs.networkluki.com-archive.asc && ! -L pkgs.networkluki.com-archive.asc ]] || die 'Public key missing or symlinked.'
  fingerprint="$(gpg --no-options --homedir "$WORK/keyring" --batch --with-colons --show-keys pkgs.networkluki.com-archive.asc | awk -F: '$1 == "fpr" { print $10 }')"
  [[ "$fingerprint" == "$EXPECTED_FPR" ]] || die 'Unexpected archive public key.'
  gpg --no-options --homedir "$WORK/keyring" --batch --import pkgs.networkluki.com-archive.asc
  verify_signatures "$ROOT_DIR/$DIST"
  validate_metadata "$ROOT_DIR/$DIST" "$ROOT_DIR/$DIST"
  python3 - "$ROOT_DIR" "$PACKAGE" "$PACKAGE_SHA" <<'PY'
import hashlib, pathlib, sys
root=pathlib.Path(sys.argv[1]); package=root/sys.argv[2]
for tree in (root/'pool/main/t/tictactoe', root/'pool/main/n/networkluki-cyberlab'):
    if not tree.is_dir() or any(p.is_symlink() for p in (tree, *tree.parents, *tree.rglob('*'))):
        raise SystemExit('Package input contains a symlink or missing directory')
if not package.is_file() or package.stat().st_size!=31177088:
    raise SystemExit('CyberLab package missing or unexpected size')
with package.open('rb') as stream:
    if hashlib.file_digest(stream, 'sha256').hexdigest()!=sys.argv[3]:
        raise SystemExit('CyberLab package checksum mismatch')
PY
  stage="$WORK/preview/$DIST"
  mkdir -p -- "$stage/main/binary-amd64"
  apt-ftparchive --arch amd64 packages pool/main/t/tictactoe > "$stage/main/binary-amd64/Packages"
  apt-ftparchive --arch amd64 packages pool/main/n/networkluki-cyberlab >> "$stage/main/binary-amd64/Packages"
  gzip -9 -n -c -- "$stage/main/binary-amd64/Packages" > "$stage/main/binary-amd64/Packages.gz"
  apt-ftparchive -o APT::FTPArchive::Release::Origin=NetworkLuki \
    -o 'APT::FTPArchive::Release::Label=NetworkLuki Packages' \
    -o APT::FTPArchive::Release::Suite=trixie -o APT::FTPArchive::Release::Codename=trixie \
    -o APT::FTPArchive::Release::Architectures=amd64 -o APT::FTPArchive::Release::Components=main \
    release "$stage" > "$WORK/Release"
  mv -- "$WORK/Release" "$stage/Release"
  validate_metadata "$stage" "$ROOT_DIR/$DIST"
  if [[ "$mode" == '--dry-run' ]]; then
    preview="$ROOT_DIR/.git/cyberlab-preview"
    if [[ -e "$preview" || -L "$preview" ]]; then
      [[ -d "$preview" && ! -L "$preview" && -f "$preview/.managed-by-cyberlab" && ! -L "$preview/.managed-by-cyberlab" ]] || die 'Unexpected preview path; move it aside manually.'
      mv -- "$preview" "$WORK/previous-preview"
    fi
    printf 'publish-cyberlab.sh\n' > "$WORK/preview/.managed-by-cyberlab"
    mv -- "$WORK/preview" "$preview"
    log INFO "Unsigned preview: $preview; live indexes are unchanged."
    return 0
  fi
  gpg --batch --list-secret-keys "$EXPECTED_FPR" >/dev/null 2>&1 || die 'Required private archive signing key is not available on this machine.'
  gpg --local-user "$EXPECTED_FPR" --digest-algo SHA256 --clearsign --output "$stage/InRelease" "$stage/Release"
  gpg --local-user "$EXPECTED_FPR" --digest-algo SHA256 --armor --detach-sign --output "$stage/Release.gpg" "$stage/Release"
  verify_signatures "$stage"
  # Recheck the baseline after any interactive signing prompt.
  verify_signatures "$ROOT_DIR/$DIST"
  validate_metadata "$ROOT_DIR/$DIST" "$ROOT_DIR/$DIST"
  validate_metadata "$stage" "$ROOT_DIR/$DIST"
  BACKUP="$(mktemp -d -- "$ROOT_DIR/.git/cyberlab-backup.XXXXXX")"
  cp -a -- "$ROOT_DIR/$DIST/." "$BACKUP/"
  REPLACING=1
  for file in "${FILES[@]}"; do atomic_copy "$stage/$file" "$ROOT_DIR/$DIST/$file"; done
  verify_signatures "$ROOT_DIR/$DIST"
  validate_metadata "$ROOT_DIR/$DIST" "$ROOT_DIR/$DIST"
  FINISHED=1
  log INFO "Signed Debian metadata prepared; previous metadata retained in $BACKUP"
  log INFO 'Review and commit dists/trixie, then push through the repository publication process.'
}
main "$@"
