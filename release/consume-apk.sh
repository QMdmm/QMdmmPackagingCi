#!/usr/bin/env bash
#
# Stage B for the apk format: the **apk** consumer.
#
# Named by consumer, like the other three: apk is the program that reads what
# this line publishes, and what it publishes is unusual among the four - there
# is no signing stage, because abuild signs the packages and the index inside
# stage A and cannot be told not to. So the artefact this cell consumes is stage
# A's own output, and the question it asks is the same one every consumer cell
# asks: with the public material a real user can get and nothing else, does this
# install, and does it install because of the key this project says signs it?
#
# Consumer-side check, run inside a clean Alpine container. Public keys come from
# Pages and from this repository's own checkout; this holds no secret at all.
#
#   env: PAGES        site root
#        LINE         distribution line, alpine
#        VERSION      the Alpine release, e.g. 3.21 - the repository's address
#        EXPECT_SHA   the publish this consumer insists on seeing
#        PACKAGER_KEY the release key's name (a NAME, not a secret)
#        PKGS         optional: stage A's out/ dir, for the version check
#
# What is checked:
#   A. the published repository + the key the site serves -> must PASS, and install
#   B. the same repository with the DAILY key instead    -> must FAIL
#
# B is the sharper half here for a reason the other lines do not have: this line
# has no keyring source, so there is no other place the claim "only the release
# key is trusted" could be read. deb and rpm both assert it by comparing a
# root-signed keyring package against the repository; apk has no keyring
# convention at all - a key is a file in /etc/apk/keys and its name is its whole
# identity, with no revocation and no signatures on keys - so the only way to
# read the claim is to hold the wrong key and watch the index be refused.
#
# The wrong key is the line's own daily one, and it is the right choice of wrong
# key: it is public, it signs the daily smoke build's packages, and a consumer
# who went looking could find it. A key nobody could obtain would prove less.
set -euo pipefail

PAGES="${PAGES:?}"; LINE="${LINE:?}"; VERSION="${VERSION:?}"
EXPECT_SHA="${EXPECT_SHA:?}"; PACKAGER_KEY="${PACKAGER_KEY:?}"
PKGS="${PKGS:-}"
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
mkdir -p "$W/keys" "$W/daily"
source "$(dirname "$0")/lib-site.sh"

KEYFILE="$PACKAGER_KEY.rsa.pub"
REPO_URL="$PAGES/$LINE/$VERSION"

echo "=== B/apk $LINE $VERSION ==="
echo "  $(os_name)"
echo "  apk: $(apk --version 2>&1 | head -1)"

echo
echo "--- tooling ---"
# curl for the site, openssl for the one reading this line has instead of a
# fingerprint. `ca-certificates` is what makes the first https request work at
# all, and a container without it fails every fetch below in a way that looks
# like a wrong URL.
apk add --no-cache curl ca-certificates openssl > "$W/tools.log" 2>&1 || {
  echo "  !! cannot install the inspection tooling:"; sed 's/^/    /' "$W/tools.log"; exit 1; }
assert_tls "$PAGES/publish.json" || exit 1

echo
echo "--- wait for the site to serve this run's publish ---"
wait_for_publish "$PAGES" "$EXPECT_SHA"

echo
echo "--- take the public key from Pages (the only channel a consumer has) ---"
fetch "$PAGES/keys/$LINE/$KEYFILE" "$W/keys/$KEYFILE"

# The key a publisher hands over is a file; the reading that gives it an
# identity is what abuild itself reports for one - sha256 of its DER public
# half. There is no OpenPGP fingerprint to compare here, so this value is the
# whole of what a consumer can check, and it is printed rather than asserted
# against a second copy of itself: the copy it IS compared against is the one
# committed in this repository, because "the site serves the key we publish" is
# a statement about two places and not about one.
der() { openssl pkey -pubin -in "$1" -outform DER 2>/dev/null | sha256sum | awk '{print $1}'; }
served_der=$(der "$W/keys/$KEYFILE")
[ -n "$served_der" ] || { echo "  !! the file the site serves as $KEYFILE is not a public key"; exit 1; }
committed="packaging/$LINE/$KEYFILE"
[ -f "$committed" ] || { echo "  !! $committed does not exist, so there is nothing to compare the served key with"; exit 1; }
committed_der=$(der "$committed")
echo "  $KEYFILE"
echo "    sha256(DER) as served:    $served_der"
echo "    sha256(DER) as committed: $committed_der"
[ "$served_der" = "$committed_der" ] \
  || { echo "  !! the site serves a different key from the one committed in packaging/$LINE"; exit 1; }
echo "  OK: the published key is the committed key"

# The other key in packaging/alpine, found rather than named: a second copy of
# its file name is a second place to forget on the day it is rotated, and the
# name is the key's whole identity here. Exactly two are expected, because
# exactly two roles exist - one that signs the published repository and one that
# signs the daily build - and a third would mean nobody has decided which of the
# three a consumer is supposed to hold.
mapfile -t pubfiles < <(find "packaging/$LINE" -maxdepth 1 -name '*.rsa.pub' | sort)
if [ "${#pubfiles[@]}" -ne 2 ]; then
  echo "  !! packaging/$LINE holds ${#pubfiles[@]} public keys, expected 2 (the release key and the daily key):"
  printf '    %s\n' "${pubfiles[@]}"
  exit 1
fi
daily=''
for f in "${pubfiles[@]}"; do
  [ "$(basename "$f")" = "$KEYFILE" ] || daily="$f"
done
[ -n "$daily" ] || { echo "  !! packaging/$LINE holds no key other than $KEYFILE"; exit 1; }
daily_der=$(der "$daily")
[ "$daily_der" != "$served_der" ] \
  || { echo "  !! $(basename "$daily") and the published key are the same key; B below would prove nothing"; exit 1; }
echo "  the other key, $(basename "$daily"): $daily_der  (a different key)"

# The index apk itself fetched, after verifying its signature. Two readings below
# come out of this and neither takes a CLI shape from apk: `apk list`, `apk
# search` and `apk info -e` all moved between apk-tools 2 and apk-tools 3, and
# this matrix spans 3.21 through edge - apk-tools 3 arrived inside that range -
# so a reading that quietly returns nothing on one generation is a cell that
# certifies nothing there. One deliberate exception: python is not assumed, so
# the cache file is found by asking which cached index carries these packages
# rather than by predicting the hash apk names it with.
#
# `P:`/`V:` are the index format's own field names and are the same on both
# generations.
cached_index() {  # cached_index <name-pattern> [--names-only]
  local pat="$1" f pairs
  for f in /var/cache/apk/APKINDEX.*.tar.gz; do
    [ -f "$f" ] || continue
    pairs=$(tar xzOf "$f" APKINDEX 2>/dev/null \
            | awk -F: '/^P:/{p=substr($0,3)} /^V:/{if(p!=""){print p"\t"substr($0,3); p=""}}' \
            | grep -E "^$pat" || true)
    if [ -n "$pairs" ]; then
      printf '%s\n' "$pairs"
      return 0
    fi
  done
  return 1
}

echo
echo "--- A) the published repository, signed by the release key ---"
install -m 644 "$W/keys/$KEYFILE" /etc/apk/keys/
echo "  installed into /etc/apk/keys:"
ls -l /etc/apk/keys/ | awk 'NR>1 {printf "    %s\n", $9}'
# The repository is named at its ROOT and not at the architecture directory:
# apk appends `<arch>/APKINDEX.tar.gz` itself, so pointing at the arch directory
# asks for `x86_64/x86_64/...` and reports a 404 that names neither the file nor
# the mistake.
echo "$REPO_URL" >> /etc/apk/repositories
echo "  | $(tail -1 /etc/apk/repositories)"
if ! apk update > "$W/update.log" 2>&1; then
  echo "  !! apk update refused the repository:"; sed 's/^/    /' "$W/update.log"; exit 1
fi
grep -iE "qmdmm|untrusted|error" "$W/update.log" | sed 's/^/    /' || true
tail -1 "$W/update.log" | sed 's/^/    /' || true

mapfile -t served < <(cached_index qmdmm | cut -f1 | sort -u)
[ "${#served[@]}" -ge 1 ] || {
  echo "  !! the index apk accepted carries no qmdmm package at all:"; exit 1; }
echo "  packages the repository serves: ${served[*]}"

# The version stage A built, against the version the accepted index carries.
# This is the reading the version check on this line exists for: an index left
# over from a previous release has the right names in it, so `served == built`
# would pass while every consumer of this repository installed the old version.
if [ -n "$PKGS" ] && [ -f "$PKGS/MANIFEST.tsv" ]; then
  built=$(built_packages "$PKGS")
  [ -n "$built" ] || { echo "  !! stage A's MANIFEST.tsv names no package"; exit 1; }
  assert_same_set "packages served vs built" "$built" "$(printf '%s\n' "${served[@]}")"
  while read -r name; do
    [ -n "$name" ] || continue
    want_ver=$(awk -F'\t' -v n="$name" '$1 == n { print $2; exit }' "$PKGS/MANIFEST.tsv")
    got_ver=$(cached_index "$name" | awk -F'\t' -v n="$name" '$1 == n { print $2; exit }')
    if [ "$want_ver" = "$got_ver" ]; then
      echo "  $name: the served version is the built version ($got_ver)"
      continue
    fi
    # Equal is the expected outcome, and unequal is only read as a disagreement
    # if the VERSION part differs. apk states a version as `<pkgver>-r<pkgrel>`
    # and both of these readings are apk's own spelling of it, but they are
    # taken from two different places (`.PKGINFO` inside the package stage A
    # built, and the `V:` field of the index apk accepted), and a cell whose
    # verdict turned on which of the two carries the revision would be a cell
    # about the format rather than about the release. What it is here to catch
    # is an index left over from another version, and that still fails.
    want_base="${want_ver%-r*}"; got_base="${got_ver%-r*}"
    [ "$want_base" = "$got_base" ] || {
      echo "  !! $name: stage A built $want_ver and the index apk accepted serves $got_ver"
      echo "     (a consumer of this repository would install $got_ver)"; exit 1; }
    echo "  $name: the version matches ($got_base); the revision reads '$want_ver' as built and '$got_ver' as served"
  done < <(printf '%s\n' "$built" | runtime_packages)
fi

runtime=$(printf '%s\n' "${served[@]}" | runtime_packages)
[ -n "$runtime" ] || { echo "  !! no runtime package to install"; exit 1; }
echo "  installing: $runtime"
if ! apk add "$runtime" > "$W/install.log" 2>&1; then
  echo "  !! install failed:"; sed 's/^/    /' "$W/install.log"; exit 1
fi
echo "  what apk installed:"
grep -E "Installing $runtime \(" "$W/install.log" | sed 's/^/    /' || true
echo "  the installed record:"
awk -F: -v n="$runtime" '/^P:/{p=substr($0,3)} /^V:/{if(p==n){print "    "p" "substr($0,3); exit}}' \
  /lib/apk/db/installed 2>/dev/null || true

{
  echo '### The apk consumer'
  echo
  echo '```'
  echo "key:         $KEYFILE  sha256(DER) $served_der"
  echo "repository:  $REPO_URL"
  echo "served:      $(printf '%s' "${served[*]}")"
  echo "installed:   $runtime"
  echo '```'
} >> "${GITHUB_STEP_SUMMARY:-/dev/null}"

echo
echo "--- B) the same repository with the DAILY key only -> must be refused ---"
# Same repository, same URL, same consumer; the release key is taken away and
# the daily key put in its place. Nothing else about the setup changes.
rm -f "/etc/apk/keys/$KEYFILE"
install -m 644 "$daily" "/etc/apk/keys/$(basename "$daily")"
echo "  /etc/apk/keys now holds:"
ls -1 /etc/apk/keys/ | sed 's/^/    /'
# The exit status is not enough, for the reason the apt half is not read on it
# either: what matters is not that `apk update` failed about something, but that
# nothing from this repository got adopted. The cache is cleared first, so the
# index the successful half above fetched cannot answer for this one.
rm -rf /var/cache/apk/*
set +e
apk update > "$W/neg.log" 2>&1
neg_rc=$?
set -e
echo "  apk update exited $neg_rc"
# A positive control inside the negative half: the upstream indexes are signed
# by keys that are still in place, so if the network or the mirrors were the
# problem there would be nothing here - which would let "nothing happened" read
# as "the wrong key was refused".
upstream=$(ls /var/cache/apk/APKINDEX.*.tar.gz 2>/dev/null | wc -l | tr -d ' ')
[ "$upstream" -ge 1 ] || {
  echo "  !! apk refreshed no repository at all, so nothing here is a verdict on the key:"
  sed 's/^/    /' "$W/neg.log"; exit 1; }
echo "  apk refreshed $upstream index(es) from repositories that are still trusted"
if cached_index qmdmm > "$W/adopted.txt"; then
  echo "  !! apk adopted an index carrying these packages, signed by $(basename "$daily"),"
  echo "     which it was never told to trust:"
  sed 's/^/    /' "$W/adopted.txt"; exit 1
fi
# And the refusal has to name the reason. A run where apk simply ignored the
# repository - a 404, a moved address - would leave the cache just as clean, and
# reading that as "the daily key is not enough" is reading a network failure as
# a security property.
if ! grep -qiE 'untrusted|not trusted' "$W/neg.log"; then
  echo "  !! apk adopted nothing from the repository, but nothing in its output names the signature either,"
  echo "     so this is not a verdict on the key:"
  sed 's/^/    /' "$W/neg.log"; exit 1
fi
echo "  OK: refused, as it must be"
grep -iE 'untrusted|not trusted|error' "$W/neg.log" | head -4 | sed 's/^/    /' || true

echo
echo "=== B/apk $LINE $VERSION: PASS ==="
