#!/usr/bin/env bash
#
# Run this on a trusted machine, NOT in CI.
#
# Builds the pacman line's trust artefact - `qmdmm-keyring` - and the
# ROOT-signed repository that serves it. It is the pacman counterpart of
# mkkeyring-deb.sh and mkkeyring-rpm.sh, and the reason sign-repo-pac.sh's header
# says the keyring package "is NOT built here" is this file: the thing that makes
# the keyring trustworthy is the root key's signature over the repository
# database, and the root secret never enters a workflow.
#
# What the package carries - and it is the whole package:
#
#   /usr/share/pacman/keyrings/qmdmm.gpg        this line's public key file
#   /usr/share/pacman/keyrings/qmdmm-trusted    the ROOT primary's fingerprint
#   /usr/share/pacman/keyrings/qmdmm-revoked    this line's retired subkeys
#
# Those three names are the interface `pacman-key --populate qmdmm` reads, and
# the path is the one pacman-key compiles in (`KEYRING_IMPORT_DIR`, pacman-key
# line ~705). There is no repository configuration in the package, and there
# cannot be: apt's `sources.list.d` and dnf's `yum.repos.d` are directories a
# package may write into, while pacman's repositories live in `/etc/pacman.conf`
# - a file another package owns. The consumer's stanza is therefore the one
# thing a user still writes by hand on this line, and the user-facing half of
# that asymmetry is in consume-pacman-keyring-package.sh's header.
#
# Why `-trusted` names the ROOT primary and not the operational subkey:
#
# `pacman-key --populate` locally signs every fingerprint in that file, and a
# primary being locally signed is what makes its SUBKEYS' signatures valid. The
# line's operational key is a subkey of the root (the same two-layer shape deb
# and rpm use), so naming the root is what makes the day-to-day database
# acceptable. Measured, not inferred: with the root in `-trusted`, `pacman -Sy`
# accepts a database signed by the operational subkey, and with `--populate`
# skipped the same container refuses it as
#   key "<subkey>" is unknown / invalid or corrupted database (PGP signature).
# `archlinux-trusted` is the same shape - five fingerprints, all primaries.
# Naming the subkey also works (measured), but it is not what the reference
# artefact does and it depends on `--lsign-key` accepting a subkey, so it is not
# what this file writes.
#
# The ownertrust level in that line is 4 (marginal), which is what
# `archlinux-trusted` uses. It is inert here: a subkey is bound to its primary by
# the subkey binding signature, not by ownertrust, and `--lsign-key` is what
# makes the primary valid. It is written out because the file is also fed to
# `gpg --import-ownertrust`, which parses it and would object to a line without
# the level.
#
# `-revoked` is the line's retired subkey fingerprints - bare 40 hex digits, one
# per line, which is `archlinux-revoked`'s shape. `pacman-key --populate` reads
# each one and runs `disable` on it, which is a global suppression: a key
# disabled here is not usable for any signature. It is derived from the same key
# file the package ships rather than kept in a second place, and it is empty -
# but present - until a line has been rotated. A rotation is therefore: the new
# subkey appears in keys/<line>/qmdmm-packages.gpg, the retired one stays there
# revoked (this is the file deb and pacman want, per FINDINGS 10.9), rebuild the
# package at a bumped version, publish, and the rotation has reached every
# consumer that populates.
#
# The database IS signed by the root key, and the package is NOT signed at all.
# That split is deliberate and it is the same argument the rpm side makes:
# `SigLevel` for a repository has two halves, and this one is
# `DatabaseRequired` with the package half off. The database carries each
# package's checksum, the database's signature is one only the root key can
# make, and a tampered package is therefore refused by a checksum inside signed
# metadata - so signing the package as well would buy nothing. What the root
# signature does buy is the UPGRADE path: a consumer who has populated already
# holds the root key, so every later fetch of this repository can be verified.
# The first install cannot be, by construction, because a machine that has never
# trusted anything has nothing to verify against; `pacman-key --populate qmdmm`
# is what ends that state, and it is the step the whole package exists for.
#
# The repository is called `qmdmm-keyring` and the package inside it is called
# `qmdmm-keyring`, which is not a coincidence: pacman asks for
# `<section>.db`, so the database's file name IS the section name a consumer has
# to write, and the only place the two can be kept equal is here. (The
# day-to-day source is called `qmdmm` for the same reason - sign-repo-pac.sh
# names its database after the section its consumers use.)
#
# PKGEXT is pinned to `.pkg.tar.zst` rather than inherited. Arch's makepkg.conf
# says `.pkg.tar.zst`, and a Debian box's says `.pkg.tar.gz` (measured on the
# builder this file defaults to); the arch line's artifacts are `.pkg.tar.zst`
# everywhere else, so leaving this to the builder's config would produce a
# correctly built package under a name the rest of the line does not recognise.
#
# Where the two halves run, and why - the same split mkkeyring-rpm.sh has:
#
#   this machine   holds the root secret, so it signs the database. It has no
#                  makepkg and no repo-add, so
#   the builder    builds the package and the database. Nothing secret goes
#                  there: the payload is public key material and two text files.
#
# What the builder must provide is makepkg and repo-add. makepkg additionally
# wants a pacman database for its dependency check, which only an Arch-family
# system has; on any other one the check cannot run and the build proceeds
# without it, saying so - remote.sh explains the probe and why the two failures
# are not the same failure. Everything else about the package - PKGEXT, the
# archive layout - is pinned here rather than inherited from the builder.
#
# usage: mkkeyring-pac.sh <line> [version] [pages-base]
# env:   PAC_BUILDER  ssh target that has makepkg and repo-add
#                     (default neve@10.31.42.18; set to "local" if this machine
#                      has both)
#        PKGVER       the package's own version (default: today's date + .1)
set -euo pipefail

cd "$(dirname "$0")/.."                      # -> repo/
source "$HOME/qmdmm-signing-prod/env.sh"     # GNUPGHOME, ROOT
source release/lib-site.sh                   # key_fpr, live_sub_fpr, count_subkeys

LINE="${1:?usage: mkkeyring-pac.sh <line> [version] [pages-base]}"
VERSION="${2:-rolling}"
BASE="${3:-${PAGES:-}}"
BUILDER="${PAC_BUILDER:-neve@10.31.42.18}"
[ -n "$BASE" ] || { echo "!! no pages base: pass it, or export PAGES"; exit 1; }

PKG=qmdmm-keyring
PKGVER="${PKGVER:-$(date -u +%Y.%m.%d).1}"
KEYDIR=/usr/share/pacman/keyrings
KEYFILE="keys/$LINE/qmdmm-packages.gpg"
# One directory per line-and-version, for the reason the deb and rpm sides each
# give: what the source offers is a specific package for a specific slot, and two
# slots sharing a directory would mean one being served under the other's name.
OUT="site/$LINE-keyring/$VERSION"

[ -f "$KEYFILE" ]           || { echo "!! $KEYFILE missing"; exit 1; }
[ -f keys/qmdmm-root.gpg ]  || { echo "!! keys/qmdmm-root.gpg missing"; exit 1; }

echo "=== keyring source for $LINE $VERSION ==="
echo "  builder: $BUILDER"
echo "  pages:   $BASE"
echo "  package: $PKG $PKGVER"
echo "  keyring: $KEYDIR/{qmdmm.gpg,qmdmm-trusted,qmdmm-revoked}"

# The root secret is what this file exists to use, so its presence is asserted
# rather than assumed - and it has to be *the* root key, not whichever key
# happens to be first in the keyring. A missing or wrong key here would produce
# a database signed by something else, and the consumer cell would report it as
# a broken scheme rather than as a wrong keyring.
echo
echo "--- the root secret, which is why this runs off-CI ---"
mapfile -t SECS < <(gpg --with-colons --list-secret-keys 2>/dev/null \
                    | awk -F: '/^sec:/{f=1;next} f&&/^fpr:/{print $10; f=0}')
[ "${#SECS[@]}" -eq 1 ] || { echo "  !! expected exactly 1 secret key in $GNUPGHOME, found ${#SECS[@]}"; exit 1; }
[ "${SECS[0]}" = "$ROOT" ] || { echo "  !! the secret key is ${SECS[0]}, not the root key $ROOT"; exit 1; }
echo "  root: $ROOT  (the only secret key here)"

# `root-fpr!` is the trailing bang that limits gpg to the primary key. Without it
# a subkey would be an acceptable signer, and "only the root key may sign the
# keyring source" would be a claim about the file rather than about the
# signature.
ROOT_KEYID="${ROOT: -16}"

# The root public key file is what the ROOT-signed source is read against, and
# the line keys are subkeys of the root - so a file that carried them as well
# would make "this source was signed by the root" indistinguishable from "by a
# line key". Same assertion, same words, as the rpm side's.
rootsub=$(count_subkeys keys/qmdmm-root.gpg)
echo "  keys/qmdmm-root.gpg  subkeys: $rootsub   (it must carry none)"
[ "$rootsub" = 0 ] \
  || { echo "  !! keys/qmdmm-root.gpg carries $rootsub subkey(s); the line keys are subkeys of the root, so this file can verify sources it must not"; exit 1; }

WORK=$(mktemp -d); RDIR=""
cleanup() {
  rm -rf "$WORK"
  # The staging directory is on the builder, so it needs removing there too -
  # including on the failure path.
  if [ -n "$RDIR" ]; then
    ssh -o BatchMode=yes -o ConnectTimeout=10 "$BUILDER" "rm -rf '$RDIR'" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT
STAGE="$WORK/stage"
mkdir -p "$STAGE/payload"
PKGDIR="$STAGE/payload/$KEYDIR"
mkdir -p "$PKGDIR"

echo
echo "--- the payload: public key material and two text files ---"
cp "$KEYFILE" "$PKGDIR/qmdmm.gpg"
sub=$(live_sub_fpr "$KEYFILE")
[ -n "$sub" ] || { echo "  !! $KEYFILE carries no usable subkey"; exit 1; }
dead=$(gpg --with-colons --show-keys "$KEYFILE" 2>/dev/null \
       | awk -F: '/^pub:/{f=0} /^sub:/{s=$2;f=1} /^fpr:/{if(f){if(s ~ /^[redi]$/){print $10} f=0}}')
echo "  qmdmm.gpg       $(wc -c < "$PKGDIR/qmdmm.gpg" | tr -d ' ') bytes   live subkey ...${sub: -16}"

printf '%s:4:\n' "$ROOT" > "$PKGDIR/qmdmm-trusted"
sed 's/^/  qmdmm-trusted   /' "$PKGDIR/qmdmm-trusted"

# Every retired subkey in the same key file, not just the first one: a line that
# has been rotated twice has two, and `disable` is per-key. dead_sub_fpr in
# lib-site.sh stops at the first, which is the right answer for "which one was
# the outgoing key" and the wrong one for "list everything this keyring must
# refuse".
printf '%s\n' "$dead" | grep -E '^[0-9A-F]{40}$' > "$PKGDIR/qmdmm-revoked" || true
if [ -s "$PKGDIR/qmdmm-revoked" ]; then
  echo "  qmdmm-revoked   this line has been rotated:"
  sed 's/^/    /' "$PKGDIR/qmdmm-revoked"
else
  echo "  qmdmm-revoked   (empty: this line has never been rotated)"
fi

cat > "$STAGE/PKGBUILD" <<EOF
# Generated by release/mkkeyring-pac.sh. It installs the three files and
# nothing else; see this file's header for why there is no repository
# configuration in it.
pkgname=$PKG
pkgver=$PKGVER
pkgrel=1
pkgdesc="QMdmm repository keyring ($LINE)"
arch=('any')
url="https://github.com/QMdmm/QMdmm"
license=('CC0-1.0')
# The files are useless without pacman-key, which is in this package.
depends=('pacman')
source=('qmdmm.gpg' 'qmdmm-trusted' 'qmdmm-revoked')
# SKIP rather than a checksum: the payload is generated in this same run from
# the repository's own keys/, so there is no upstream artefact to pin. What the
# package ends up carrying is asserted after the build instead, on the built
# package itself, which is the reading that cannot drift.
sha256sums=('SKIP' 'SKIP' 'SKIP')

package() {
  install -Dm644 qmdmm.gpg     "\$pkgdir$KEYDIR/qmdmm.gpg"
  install -Dm644 qmdmm-trusted "\$pkgdir$KEYDIR/qmdmm-trusted"
  install -Dm644 qmdmm-revoked "\$pkgdir$KEYDIR/qmdmm-revoked"
}
EOF

# What runs over there. Written into the payload rather than piped through an
# interpolating heredoc, so that no quoting layer sits between this file and what
# the builder executes.
cat > "$STAGE/remote.sh" <<'REMOTE'
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

echo "  $(sed -n 's/^PRETTY_NAME="\(.*\)"$/\1/p' /etc/os-release 2>/dev/null | head -1)"
echo "  makepkg: $(makepkg --version | head -1)"
# pacman's banner opens with a blank line, so `head -1` of it is empty; the
# version is what is wanted and it is the one ASCII part of that banner.
echo "  pacman:  $(pacman --version | grep -m1 -o 'Pacman v.*')"
echo "  repo-add: $(command -v repo-add)"

T="$PWD/build"
rm -rf "$T"; mkdir -p "$T"
cp payload/usr/share/pacman/keyrings/* "$T/"
cp PKGBUILD "$T/"

# makepkg's dependency check runs `pacman -T`, and pacman needs a database it can
# write its lock into. On a builder that is not an Arch system - this file's
# default is a Debian box, where makepkg comes from the pacman-package-manager
# package - libalpm cannot create that lock, pacman exits 255, and makepkg stops
# with "'pacman' returned a fatal error". That is not the same as a missing
# dependency, and only one of the two may be skipped:
#
#   rc 0    pacman is in the builder's database -> the check is real
#   rc 127  the database is fine, the package is not in it -> makepkg's own
#           business, and it prints the name (measured: 127 against a writable
#           dbpath, 255 against this builder's)
#   rc 255  the check cannot run at all
#
# So probe, and skip only the third case - loudly, because a silently skipped
# check reads as a passing one.
MAKEPKG_FLAGS=(-f --noconfirm --noprogressbar)
probe=0
pacman -T pacman >/dev/null 2>&1 || probe=$?
if [ "$probe" = 255 ]; then
  echo "  note: this builder has no usable pacman database, so makepkg's"
  echo "        dependency check cannot run. Building with --nodeps; the only"
  echo "        dependency declared is 'pacman' itself, which every consumer of"
  echo "        this package has by definition."
  MAKEPKG_FLAGS+=(--nodeps)
fi

# PKGEXT is pinned rather than inherited - see mkkeyring-pac.sh's header. The
# builder's own makepkg.conf is not this line's to depend on.
( cd "$T" && PKGEXT='.pkg.tar.zst' PACKAGER='QMdmm Packaging <nemn9852@agent.qq.com>' \
    makepkg "${MAKEPKG_FLAGS[@]}" ) > "$PWD/makepkg.log" 2>&1 || {
  echo "  !! makepkg failed:"; tail -25 "$PWD/makepkg.log" | sed 's/^/    /'; exit 1; }
PKGFILE=$(ls "$T"/qmdmm-keyring-*.pkg.tar.zst)
echo "  built: $(basename "$PKGFILE")  ($(wc -c < "$PKGFILE" | tr -d ' ') bytes)"
pacman -Qip "$PKGFILE" 2>/dev/null | grep -E '^(Name|Version|Architecture|Depends On)' | sed 's/^/    /' || true

# Assert the payload really is in it, rather than trusting the build log or the
# recipe. Names are read out of the package rather than globbed: a glob in a
# `for` list expands against THIS machine's filesystem.
bsdtar -tf "$PKGFILE" > contents.txt
echo "  contents:"
sed 's/^/    /' contents.txt
for f in usr/share/pacman/keyrings/qmdmm.gpg \
         usr/share/pacman/keyrings/qmdmm-trusted \
         usr/share/pacman/keyrings/qmdmm-revoked; do
  grep -qx "$f" contents.txt || { echo "  !! the package does not carry $f"; exit 1; }
done

OUT="$PWD/out"
rm -rf "$OUT"; mkdir -p "$OUT"
cp "$PKGFILE" "$OUT"

# The database is named for the SECTION a consumer will write, because that is
# the file pacman asks for - see mkkeyring-pac.sh's header. Signed here only in
# the sense that repo-add is told to sign nothing: the root secret is not on this
# machine, so the signature is made on the trusted machine and lands beside this
# database afterwards.
( cd "$OUT" && repo-add -q qmdmm-keyring.db.tar.gz ./*.pkg.tar.zst )
echo "  database:"
find "$OUT" -type f | sort | sed 's/^/    /'
REMOTE

echo
echo "--- build the package and the database on the builder ---"
if [ "$BUILDER" = local ]; then
  ( cd "$STAGE" && bash remote.sh )
else
  RDIR=/tmp/qmdmm-keyring-$$-$RANDOM
  # --no-xattrs: macOS tar otherwise writes the BSD xattr headers, and GNU tar on
  # the far side answers each one with an "unknown extended header keyword"
  # warning that buries the real build output.
  tar --no-xattrs -C "$STAGE" -cf - . \
    | ssh -o BatchMode=yes -o ConnectTimeout=10 "$BUILDER" \
        "rm -rf $RDIR && mkdir -p $RDIR && tar --warning=no-unknown-keyword -C $RDIR -xf -" \
    || { echo "  !! cannot stage the build on $BUILDER"; exit 1; }
  ssh -o BatchMode=yes -o ConnectTimeout=10 "$BUILDER" "cd $RDIR && bash remote.sh" || {
    echo "  !! the build failed on $BUILDER"; exit 1; }
  # -h so the database's .db / .files symlinks come back as files rather than as
  # links pointing at names nothing has created on this side yet.
  ssh -o BatchMode=yes -o ConnectTimeout=10 "$BUILDER" "tar -C $RDIR/out -cf - ." > "$WORK/out.tar" \
    || { echo "  !! cannot collect the build from $BUILDER"; exit 1; }
fi

echo
echo "--- stage it at its published path ---"
rm -rf "$OUT"; mkdir -p "$OUT"
if [ "$BUILDER" = local ]; then
  cp -r "$STAGE/out/." "$OUT/"
else
  tar -C "$OUT" -xf "$WORK/out.tar"
fi
find "$OUT" -type f | sort | sed 's/^/  /'
[ -f "$OUT/qmdmm-keyring.db.tar.gz" ] \
  || { echo "  !! no qmdmm-keyring.db.tar.gz came back from the builder"; exit 1; }
ls "$OUT"/qmdmm-keyring-*.pkg.tar.zst >/dev/null 2>&1 \
  || { echo "  !! no qmdmm-keyring package came back from the builder"; exit 1; }

echo
echo "--- sign the database with the ROOT key ---"
# Both databases repo-add produced, and the .db / .files symlinks pacman actually
# asks for: pacman fetches `<name>.db.sig` and `<name>.files.sig`, and those are
# symlinks repo-add creates to the .tar.gz names. A repository signed by hand
# afterwards has to recreate them.
for what in db files; do
  gpg --batch --yes --local-user "${ROOT}!" --detach-sign \
      -o "$OUT/qmdmm-keyring.$what.tar.gz.sig" "$OUT/qmdmm-keyring.$what.tar.gz"
  cp -f "$OUT/qmdmm-keyring.$what.tar.gz.sig" "$OUT/qmdmm-keyring.$what.sig"
done
chmod 644 "$OUT"/qmdmm-keyring-*.pkg.tar.zst "$OUT"/*.sig

# Which key signed it, from the status stream rather than from the exit code:
# `gpg --verify` calls a signature good whatever key made it, so the exit code
# cannot tell the root key from a subkey (FINDINGS 3.1 is the same shape).
for what in db files; do
  gpgv --keyring keys/qmdmm-root.gpg --status-fd 3 \
       "$OUT/qmdmm-keyring.$what.tar.gz.sig" "$OUT/qmdmm-keyring.$what.tar.gz" \
       3> "$WORK/status-$what" || true
  signer=$(awk '/^\[GNUPG:\] GOODSIG /{print $3}' "$WORK/status-$what" | head -1)
  echo "  $what: signer ${signer:-<none>}   expected: $ROOT_KEYID"
  [ "$signer" = "$ROOT_KEYID" ] \
    || { echo "  !! the keyring source's $what database is not signed by the root key"; exit 1; }
done
echo "  OK: the keyring source verifies under the root key alone"

echo
echo "=== built $OUT ==="
echo "  The one thing a user on this line still writes by hand - and the reason"
echo "  this file prints it, since the path is known here and nowhere else - is"
echo "  the stanza that reads this source. Nothing else in the block is needed:"
echo "  from then on the package's own trust is what the repositories are read"
echo "  under."
echo
echo "    [$PKG]                                    # the first one, only"
echo "    SigLevel = Never                          # nothing to check against yet"
# `site/.` is what the publish job copies to the root of the Pages site, so the
# directory this file writes to and the path a consumer reads are not the same
# string: the prefix has to come off. The deb and rpm sides each compose their
# own URL the same way, and a stanza that kept the prefix would 404 silently on
# the first `pacman -Sy` - pacman reads a missing source as an empty one.
echo "    Server = $BASE/${OUT#site/}"
echo
echo "    pacman -Sy && pacman -S $PKG"
echo "    pacman-key --populate qmdmm"
echo
echo "  and afterwards, the day-to-day source, which the trust just established"
echo "  CAN be checked:"
echo
echo "    [qmdmm]"
echo "    SigLevel = Required DatabaseRequired"
echo "    Server = $BASE/$LINE/$VERSION"
echo
echo "  NEXT: re-run this for the other lines, then commit and dispatch:"
echo "    git add $OUT && git commit && git push"
echo "    dispatch release.yml - the arch and manjaro trust cells read it back,"
echo "    and the consumer cells walk the bootstrap above."
