#!/usr/bin/env bash
#
# Run this on a trusted machine, NOT in CI.
#
# Builds a minimal apt repository tree and signs its InRelease with a given key.
# Used for the parts of the scheme that must not go through CI:
#
#   - the keyring source, which only the root key may sign (if the trust root
#     never enters a workflow, a compromised workflow cannot replace it);
#   - frozen fixtures, e.g. "a source signed by the subkey that was later
#     revoked", kept around so a consumer-side test can prove it gets rejected.
#
# It also writes this repository's priority discipline into the Release header -
# see the note at the fields themselves. Both callers get it: the keyring source
# built here on a trusted machine, and the day-to-day source built by
# sign-repo-deb.sh in CI.
#
# usage: mkrepo-debian.sh <key-fpr> <outdir> [suite] [description]
set -euo pipefail

KEY="${1:?usage: mkrepo-debian.sh <key-fpr> <outdir> [suite] [description]}"
OUT="${2:?usage: mkrepo-debian.sh <key-fpr> <outdir> [suite] [description]}"
SUITE="${3:-sid}"
DESC="${4:-QMdmm apt repository}"

cd "$(dirname "$0")/.."                      # -> repo/
# No local keyring is sourced here: doing so would name a trusted-machine file
# that does not exist in CI, which once took all five deb rows down with "No
# such file or directory" while the rpm and pacman rows passed. The key is an
# argument; the keyring is whatever the calling script imported.
source release/lib-tools.sh                  # md5_of / sha_of / deb_control

D="$OUT/dists/$SUITE"
ARCHDIR="$D/main/binary-all"

echo "=== building $OUT (suite $SUITE) with key $KEY ==="

mkdir -p "$ARCHDIR"
# If the repo carries packages in pool/, describe them for real (control is
# read straight out of the .deb with ar+tar, since there is no dpkg-deb).
# Otherwise emit a placeholder entry so Release still has something to list.
found=0
while IFS= read -r deb; do
  rel="${deb#"$OUT"/}"
  ctrl=$(deb_control "$deb")
  printf '%s\n' "$ctrl" | grep -v '^$'
  printf 'Filename: %s\n' "$rel"
  printf 'Size: %s\n' "$(wc -c < "$deb" | tr -d ' ')"
  printf 'MD5sum: %s\n' "$(md5_of "$deb")"
  printf 'SHA256: %s\n' "$(sha_of "$deb")"
  printf '\n'
  found=1
done < <(find "$OUT/pool" -name '*.deb' 2>/dev/null | sort) > "$ARCHDIR/Packages"
if [ "$found" = 0 ]; then
  {
    echo "Package: qmdmm"
    echo "Version: 1.0"
    echo "Architecture: all"
    echo "Maintainer: QMdmm Packaging <nemn9852@agent.qq.com>"
    echo "Description: $DESC"
  } > "$ARCHDIR/Packages"
fi
gzip -kf "$ARCHDIR/Packages"

{
  echo "Origin: QMdmm"
  echo "Label: QMdmm"
  # Suite and Codename have to name the suite the tree is actually under. They
  # used to be the literal string "stable" while the directory was dists/<suite>,
  # and apt answers a mismatched Suite with "Conflicting distribution" and then
  # treats the source with suspicion - which is a strange thing to hand a
  # consumer in a lab whose whole point is that apt accepts this repository.
  echo "Suite: $SUITE"
  echo "Codename: $SUITE"
  # The pair below is this repository's priority discipline, and it is what keeps
  # a third party a third party. Measured, with every apt directory redirected to
  # a scratch tree and nothing actually installed, on Debian forky's apt 3.3.3 -
  # which is also the deb rows' own distribution - against a stand-in
  # distribution of a different origin that ships this package name at a version
  # below the one in this pool. That is the case that matters - a third party
  # taking a name over is only a problem when the name is not ours alone:
  #
  #   no fields             the higher version here becomes the candidate, so the
  #                         repository takes a distribution's name over;
  #   NotAutomatic alone    the distribution keeps the candidate, but an
  #                         installed package stops upgrading - the whole source
  #                         is frozen, the keyring package included, and that
  #                         package is the carrier a key rotation travels on;
  #   this pair             a fresh install and an upgrade behave exactly as they
  #                         do under Pin-Priority: 100, and the distribution
  #                         still keeps the candidate.
  #
  # It is a field of the source rather than a preferences file carried by the
  # keyring package, so it also reaches the consumers who configure the source by
  # hand and never install that package, and it needs no package version to move.
  # `Pin-Priority: 1` - the value that was proposed before that measurement - is
  # not merely like `NotAutomatic` alone: that source is the one apt reads at
  # priority 1. No distribution ships any of these package names today, so this is
  # a standing rule rather than the repair of an observable takeover.
  echo "NotAutomatic: yes"
  echo "ButAutomaticUpgrades: yes"
  echo "Date: $(date -u '+%a, %d %b %Y %H:%M:%S UTC')"
  echo "Architectures: all"
  echo "Components: main"
  echo "Description: $DESC"
  echo "MD5Sum:"
  printf ' %s %16s %s\n' "$(md5_of "$ARCHDIR/Packages")"    "$(wc -c < "$ARCHDIR/Packages"    | tr -d ' ')" "main/binary-all/Packages"
  printf ' %s %16s %s\n' "$(md5_of "$ARCHDIR/Packages.gz")" "$(wc -c < "$ARCHDIR/Packages.gz" | tr -d ' ')" "main/binary-all/Packages.gz"
  echo "SHA256:"
  printf ' %s %16s %s\n' "$(sha_of "$ARCHDIR/Packages")"    "$(wc -c < "$ARCHDIR/Packages"    | tr -d ' ')" "main/binary-all/Packages"
  printf ' %s %16s %s\n' "$(sha_of "$ARCHDIR/Packages.gz")" "$(wc -c < "$ARCHDIR/Packages.gz" | tr -d ' ')" "main/binary-all/Packages.gz"
} > "$D/Release"

gpg --batch --yes --local-user "${KEY}!" --clearsign -o "$D/InRelease" "$D/Release"

echo "  --- who signed it ---"
gpg --verify "$D/InRelease" 2>&1 | sed 's/^/    /'
echo "  --- output ---"
find "$OUT" -type f | sort | sed 's/^/    /'
