#!/usr/bin/env bash
#
# Run this on a trusted machine, NOT in CI.
#
# Builds <repo>-archive-keyring: the one .deb a consumer installs to get BOTH
# sources configured. Debian's own wiki explicitly allows this shape - a
# keyring package MUST ship the certificates under /usr/share/keyrings and MAY
# also ship sources.list.d entries.
#
# What it carries:
#   /usr/share/keyrings/qmdmm-root.gpg        root public key only
#   /usr/share/keyrings/qmdmm-packages.gpg    every key file under keys/<distro>/,
#                                             concatenated as they are
#   /etc/apt/sources.list.d/qmdmm.sources     both repos, each naming its file
#
# The line's key material is a SET, and a rotation window is the state where that
# set has two members. Every *.gpg directly under keys/<distro>/ is concatenated
# into the one file apt is pointed at -- `Signed-By: /usr/share/keyrings/
# qmdmm-packages.gpg` is a single path, so a second file sitting beside that one
# would be installed and then never read, which is the whole reason this tool
# concatenates instead of copying named files. Rotating a line's signing subkey
# is therefore: drop the export being retired into the line's directory as a
# second file, rebuild the package at a bumped version, publish it, and delete
# the retired file in a later version. Until that delete the package accepts
# repositories signed by either subkey -- that overlap is the point, the outgoing
# subkey keeps signing while every consumer picks the new one up -- and after it
# the retired subkey's signatures are refused. The set of files IS the record of
# where a rotation stands: what is present says what is accepted, and there is
# nothing to keep in step beside it. Deleting a file too early is a refusal on
# the consumer side rather than a silent acceptance, so the mistake is loud.
#
# A single file that already carries both subkeys satisfies the same rule with no
# second file -- one file in, the same bytes out -- and that is the shape a
# rotation of a line's own primary produces. It is also the wider-reaching one of
# the two: the site publishes keys/<line>/ verbatim and the consumer cells fetch
# qmdmm-packages.gpg by that name, so a line rotated by adding a subkey to its
# single file reaches those paths too, while one rotated by staging a second file
# covers the keyring package only. Both shapes are accepted here; the condition
# either way is the same, that the outgoing subkey is still live and still
# present in the set.
#
# Each file is a full export (the root, or a primary, plus whatever subkeys it
# was exported with), so a stack repeats the primary once per member. That is
# deliberate and harmless: a keyring is a set of keys, gpg and apt merge a
# repeated key rather than count it twice, and no file has to be edited to
# withdraw one subkey.
#
# Note there is deliberately no .deb signature. apt does not review signatures
# at the package level at all; what protects this package is that it is served
# from the ROOT-signed keyring source, whose InRelease only the root key can
# sign. That is the whole reason the keyring source exists as a separate repo.
#
# One invocation builds ONE suite, and each suite gets its own repository
# directory (`<pages>/<distro>-keyring/<suite>`). The reason is in the payload:
# the sources.list.d entry below bakes `Suites: $SUITE` into the machine that
# installs the package. A trixie consumer handed the sid package would have
# their day-to-day source pointed at `debian/sid` - a wrong distribution, and
# one that only looks harmless while the two happen to carry the same build.
#
# usage: mkkeyring-deb.sh <distro> <pages-base> [version]
# env:   SUITE  the distribution this package configures (default sid)
# TRUSTED-MACHINE TOOL, not a CI step.
# It sources the local keyring env on purpose: the keyring package is the thing
# the ROOT key signs, and the root secret never enters CI. A CI job must not
# call this file - stage S signs the day-to-day source with a subkey only.
set -euo pipefail

cd "$(dirname "$0")/.."                      # -> repo/
source "$HOME/qmdmm-signing-prod/env.sh"     # GNUPGHOME, ROOT
source release/lib-tools.sh                  # md5_of

DISTRO="${1:?usage: mkkeyring-deb.sh <distro> <pages-base> [version]}"
BASE="${2:?usage: mkkeyring-deb.sh <distro> <pages-base> [version]}"
VERSION="${3:-$(date -u +%Y.%m.%d).1}"
SUITE="${SUITE:-sid}"
PKG="qmdmm-archive-keyring"

[ -d "keys/$DISTRO" ] || { echo "!! keys/$DISTRO is not a directory"; exit 1; }
mapfile -t KEYFILES < <(find "keys/$DISTRO" -maxdepth 1 -type f -name '*.gpg' | LC_ALL=C sort)
[ "${#KEYFILES[@]}" -ge 1 ] || { echo "!! keys/$DISTRO carries no *.gpg"; exit 1; }

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
ROOT="$WORK/root"
mkdir -p "$ROOT/DEBIAN" "$ROOT/usr/share/keyrings" "$ROOT/etc/apt/sources.list.d"

cp keys/qmdmm-root.gpg            "$ROOT/usr/share/keyrings/qmdmm-root.gpg"
cat "${KEYFILES[@]}" > "$ROOT/usr/share/keyrings/qmdmm-packages.gpg"
chmod 644 "$ROOT/usr/share/keyrings/"*.gpg

cat > "$ROOT/etc/apt/sources.list.d/qmdmm.sources" <<EOF
Types: deb
URIs: $BASE/$DISTRO-keyring/$SUITE
Suites: $SUITE
Components: main
Signed-By: /usr/share/keyrings/qmdmm-root.gpg

Types: deb
URIs: $BASE/$DISTRO/$SUITE
Suites: $SUITE
Components: main
Signed-By: /usr/share/keyrings/qmdmm-packages.gpg
EOF
chmod 644 "$ROOT/etc/apt/sources.list.d/qmdmm.sources"

cat > "$ROOT/DEBIAN/control" <<EOF
Package: $PKG
Version: $VERSION
Architecture: all
Maintainer: QMdmm Packaging <nemn9852@agent.qq.com>
Section: misc
Priority: optional
Description: QMdmm archive signing keys and repository configuration
 Ships the QMdmm root public key, this distribution's operational
 subkey, and the sources.list.d entries for both the keyring source
 and the day-to-day source. Installing it configures both repos.
EOF

# md5sums, as a package should have
( cd "$ROOT" && find . -type f ! -path './DEBIAN/*' | sed 's|^\./||' | sort | \
  while read -r f; do printf '%s  %s\n' "$(md5_of "$f")" "$f"; done \
) > "$ROOT/DEBIAN/md5sums"

# One directory per suite, not one per distribution. `mkrepo-debian.sh` lists
# every .deb it finds under `$OUT/pool` into the suite it is writing, so two
# suites sharing a pool would each advertise both keyring packages - and since
# each package bakes its own `Suites:`, apt could install the one belonging to
# the other distribution. Keeping the pool inside the suite's directory makes
# that unrepresentable. (This tool is run once per suite; the directory is what
# the consumer's bootstrap stanza names.)
OUT="site/$DISTRO-keyring/$SUITE"
POOL="$OUT/pool/main/q/$PKG"
mkdir -p "$POOL"
rm -f "$POOL"/*.deb
DEB="$(cd "$POOL" && pwd)/${PKG}_${VERSION}_all.deb"

# dpkg-deb is the tool for this, and the only one used: it is what any
# Debian-ish box (or the debian container this belongs in) has.
dpkg-deb --build --root-owner-group "$ROOT" "$DEB" > /dev/null
echo "  built with dpkg-deb"

echo "=== built $DEB ==="
ls -l "$DEB" | awk '{printf "  %s bytes\n", $5}'
echo "  --- key files ---"
printf '    %s\n' "${KEYFILES[@]}"
if [ "${#KEYFILES[@]}" -gt 1 ]; then
  echo "  note: ${#KEYFILES[@]} key files stacked -- a rotation window is open, and the"
  echo "        package accepts repositories signed by either subkey until the retired"
  echo "        file is deleted (see the top of this file)."
fi
echo "  --- contents ---"
( cd "$ROOT" && find . -type f ! -path './DEBIAN/*' | sort | sed 's/^/    /' )
echo "  --- control ---"
sed 's/^/    /' "$ROOT/DEBIAN/control"
echo
echo "  NEXT: re-sign the keyring source so it serves this package:"
echo "    bash release/mkrepo-debian.sh <root-fpr> $OUT $SUITE"
