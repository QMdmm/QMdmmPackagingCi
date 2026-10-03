#!/usr/bin/env bash
#
# Stage B for the half of the scheme that is not a day-to-day repository: the
# root-signed keyring source.
#
# One cell per deb suite. The keyring source is per suite - the package it
# carries bakes `Suites:` into the consumer's sources.list.d - so a source
# serving the wrong suite is a *wrong* answer rather than a missing one, and the
# only way to see that is to look at each suite's own directory. Installing the
# package the source carries is consume-keyring-package.sh's half, one cell per
# suite as well.
#
#   env: PAGES, LINE, VERSION, ROOT_FPR, EXPECT_SHA
#
# What is checked: the keyring source verifies under the ROOT public key alone,
# and the signer really is the root key - not a subkey that happens to be in the
# same file. That is the whole point of the keyring source existing as its own
# repository: it is the one thing only the root key may sign.
#
# The assertion reads `--status-fd`, never the exit code, because FINDINGS.md
# 3.1 measured what the exit code is worth: `gpg --verify` prints "Good
# signature" and exits 0 for a signer whose key was revoked, adding only a
# WARNING line - so anything built on the exit code passes on exactly the input
# it exists to catch.
#
# The lab's copy of this script carried a second half - a fixture signed by a
# subkey that was later revoked, asserted to come back REVKEYSIG rather than
# GOODSIG. That fixture is not here, and cannot be: it is a reading about an
# incident, it needs a revoked subkey to exist, and a release has none. This
# workflow is a publisher, not a rehearsal of a compromise; the lab is where
# that belongs.
set -euo pipefail

PAGES="${PAGES:?}"; ROOT_FPR="${ROOT_FPR:?}"; EXPECT_SHA="${EXPECT_SHA:?}"
LINE="${LINE:?}"; VERSION="${VERSION:?}"
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
mkdir -p "$W/keys" "$W/keyring"
source "$(dirname "$0")/lib-site.sh"

ROOT_KEYID="${ROOT_FPR: -16}"

echo "=== B/keyring (the root-signed source) $LINE $VERSION ==="
echo "  $(os_name)"

echo
echo "--- tooling ---"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq </dev/null
# gpgv is its own package in Debian - gnupg does not pull it in - and this script
# is written against gpgv, so it has to be asked for by name. (It was not, and
# the first run got as far as `gpgv: command not found` before giving up.)
apt-get install -y -qq --no-install-recommends gnupg gpgv curl ca-certificates </dev/null
command -v gpgv >/dev/null \
  || { echo "  !! gpgv is missing, and every check below is written against it"; exit 1; }
echo "  gpgv: $(command -v gpgv)"
assert_tls "$PAGES/publish.json" || exit 1

echo
echo "--- wait for the site to serve this run's publish ---"
wait_for_publish "$PAGES" "$EXPECT_SHA"

echo
echo "--- keys, from Pages only ---"
fetch "$PAGES/keys/qmdmm-root.gpg"           "$W/keys/root.gpg"
fetch "$PAGES/keys/$LINE/qmdmm-packages.gpg" "$W/keys/packages.gpg"
[ "$(key_fpr "$W/keys/root.gpg")" = "$ROOT_FPR" ] \
  || { echo "  !! the root key file is not $ROOT_FPR"; exit 1; }
echo "  root file:     $(count_subkeys "$W/keys/root.gpg") subkey(s), as it must have"
echo "  packages file: $(count_subkeys "$W/keys/packages.gpg") subkey(s)"

echo
echo "--- fetch the off-CI source ---"
fetch "$PAGES/$LINE-keyring/$VERSION/dists/$VERSION/InRelease" "$W/keyring/InRelease"

echo
echo "--- A) the keyring source, verified under the ROOT key alone ---"
# --status-fd is the machine-readable half of the answer; the human text is kept
# only for the log.
gpgv --keyring "$W/keys/root.gpg" --status-fd 3 "$W/keyring/InRelease" \
     3> "$W/status.a" 2> "$W/gpgv.a" || true
sed 's/^/    /' "$W/gpgv.a"
signer=$(awk '/^\[GNUPG:\] GOODSIG /{print $3}' "$W/status.a" | head -1)
if [ -z "$signer" ]; then
  echo "  !! the keyring source does not verify under the root key at all"
  sed 's/^/    /' "$W/status.a"; exit 1
fi
echo "  signer: $signer   expected: $ROOT_KEYID"
[ "$signer" = "$ROOT_KEYID" ] \
  || { echo "  !! the keyring source was signed by $signer, not by the root key"; exit 1; }
echo "  OK: the keyring source is signed by the root key"

echo
echo "=== B/keyring: PASS ==="
