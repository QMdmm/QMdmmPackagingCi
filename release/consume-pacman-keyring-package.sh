#!/usr/bin/env bash
#
# Stage B for the pacman trust bootstrap: install the keyring PACKAGE, and check
# that a user who then populates ends up able to read the line's repository.
#
# The deb counterpart is consume-keyring-package.sh and the rpm one is
# consume-dnf-keyring-package.sh. This is the pacman half of the same claim, and
# the reason it is a separate script rather than a branch in consume-pacman.sh is
# the split trust-keyring and trust-consume exist for: "the keyring arrives as an
# installable package" and "a consumer that has it can read the repository" are
# different claims, and a cell that did both would not say which one broke.
#
# Consumer-side check, run inside a clean archlinux:base / manjarolinux:base
# container. Public keys come from Pages only; this holds no secret at all.
#
#   env: PAGES, LINE, VERSION, ROOT_FPR, EXPECT_SHA
#
# What is checked:
#   0. the keyring source's database really is signed by the ROOT key - read
#      straight off the published bytes, so that the claim does not depend on
#      pacman agreeing. (pacman cannot check it on this machine: see A.)
#   A. under a stanza that checks nothing, the keyring source offers exactly one
#      package and installing it puts the three files where pacman-key looks for
#      them - the one bootstrap step a user does by hand on this line
#   B. the three files are what the design says they are: qmdmm.gpg is this
#      line's published key file, -trusted names the root, -revoked is present
#      and (until a line is rotated) empty
#   C. THE CONTROL: with the files in place and `pacman-key --populate` NOT run,
#      the day-to-day source is refused. This is the reading that says the files
#      being on disk is not trust - criterion and negative half in one, and the
#      reason this cell is not satisfied by "the package installed".
#   D. `pacman-key --populate qmdmm` - and the same source is accepted, and
#      offers this line's packages.
#
# Why a stanza that checks nothing is not a hole invented here: pacman's trust
# store is global and starts empty, so a machine that has never trusted anything
# has nothing to check a first package against. What protects the bootstrap is
# the step after it - D reads a database signed by the line's operational subkey,
# and it fails loudly if the package that was installed was not the real keyring.
# The published signature read in 0 is the artefact-level half of that, and it is
# the half that does not depend on this container's state at all.
#
# One cell per line. The package's name and the section a consumer writes are the
# same string by construction (mkkeyring-pac.sh's header), and the slot it is
# published in is `$LINE-keyring/$VERSION` - so a package built for one line and
# served to another would install, populate, and leave the consumer trusting a
# key that does not sign what it is about to read.
set -euo pipefail

PAGES="${PAGES:?}"; LINE="${LINE:?}"; VERSION="${VERSION:?}"
ROOT_FPR="${ROOT_FPR:?}"; EXPECT_SHA="${EXPECT_SHA:?}"
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
mkdir -p "$W/gh"; chmod 700 "$W/gh"
source "$(dirname "$0")/lib-site.sh"

# The section name of the keyring source is also its database's name, and both
# are the package's name - that is what makes the stanza below able to find it.
KR=qmdmm-keyring
# The day-to-day source, named in sign-repo-pac.sh and read by consume-pacman.sh.
REPO=qmdmm
KEYDIR=/usr/share/pacman/keyrings

echo "=== B/keyring-package (pacman) $LINE $VERSION ==="
echo "  $(os_name)"
echo "  pacman: $(pacman --version | head -1)"

echo
echo "--- tooling ---"
pacman_tools
command -v gpg  >/dev/null || { echo "  !! gpg is missing"; exit 1; }
command -v curl >/dev/null || { echo "  !! curl is missing"; exit 1; }
assert_tls "$PAGES/publish.json" || exit 1
# pacman-key has to SIGN with the local keyring's master key to populate at all,
# so the question is not "is there a keyring" - Arch's base image ships one,
# filled with the distribution's public keys and with no secret key at all.
# Without this, --populate dies with "There is no secret key available to sign
# with", which is a message about the keyring and looks nothing like the actual
# problem: a container that has never needed to sign anything.
if ! gpg --homedir /etc/pacman.d/gnupg --list-secret-keys 2>/dev/null | grep -q '^sec'; then
  echo "  (the pacman keyring has no secret key; creating one)"
  pacman-key --init
  gpg --homedir /etc/pacman.d/gnupg --list-secret-keys 2>/dev/null | grep -q '^sec' \
    || { echo "  !! pacman-key --init did not produce a key this keyring can sign with"; exit 1; }
fi
echo "  pacman keyring can sign: yes"

echo
echo "--- wait for the site to serve this run's publish ---"
wait_for_publish "$PAGES" "$EXPECT_SHA"

echo
echo "--- 0) the keyring source, verified against the published bytes ---"
# Independent of pacman and of this container's trust store: stage A of this
# line's trust chain is a claim about a signature, and whether pacman can act on
# it is then a separate reading in A below. Same shape as the rpm cell's step 0
# and as consume-apt-keyring.sh.
fetch "$PAGES/keys/qmdmm-root.gpg"                      "$W/root.gpg"
fetch "$PAGES/$LINE-keyring/$VERSION/$KR.db"            "$W/$KR.db"
fetch "$PAGES/$LINE-keyring/$VERSION/$KR.db.sig"        "$W/$KR.db.sig"
rootfpr=$(key_fpr "$W/root.gpg")
nsub=$(count_subkeys "$W/root.gpg")
echo "  root key file: $rootfpr   subkeys: $nsub"
[ "$rootfpr" = "$ROOT_FPR" ] || { echo "  !! the published root key is $rootfpr, not $ROOT_FPR"; exit 1; }
[ "$nsub" = 0 ] \
  || { echo "  !! the root pin carries $nsub subkey(s); the line keys are subkeys of the root, so this file can verify sources it must not"; exit 1; }
gpg --homedir "$W/gh" --batch --quiet --import "$W/root.gpg" 2>/dev/null
gpg --homedir "$W/gh" --status-fd 3 --verify "$W/$KR.db.sig" "$W/$KR.db" \
    3> "$W/status" > "$W/gpgv.log" 2>&1 || true
signer=$(awk '/^\[GNUPG:\] GOODSIG /{print $3}' "$W/status" | head -1)
echo "  signer: ${signer:-<none>}   expected: ${ROOT_FPR: -16}"
[ "$signer" = "${ROOT_FPR: -16}" ] \
  || { echo "  !! the keyring source is not signed by the root key:"; sed 's/^/    /' "$W/gpgv.log"; exit 1; }
echo "  OK: signed by the root key, and the signature is over these bytes"

echo
echo "--- A) the one bootstrap step: read the keyring source under a stanza that checks nothing ---"
cp /etc/pacman.conf "$W/pacman.conf.orig"
cat >> /etc/pacman.conf <<EOF

[$KR]
SigLevel = Never
Server = $PAGES/$LINE-keyring/$VERSION
EOF
echo "  | [$KR]  SigLevel = Never  Server = $PAGES/$LINE-keyring/$VERSION"
if ! pacman -Sy --noconfirm > "$W/sy1.log" 2>&1; then
  echo "  !! pacman -Sy refused the keyring source:"; sed 's/^/    /' "$W/sy1.log"; exit 1
fi
grep -iE "$KR|error" "$W/sy1.log" | sed 's/^/    /' || true
mapfile -t offered < <(pacman -Sl "$KR" 2>/dev/null | awk '{print $2}' | sort -u || true)
echo "  the keyring source offers: ${offered[*]:-<none>}"
[ "${#offered[@]}" -eq 1 ] && [ "${offered[0]}" = "$KR" ] \
  || { echo "  !! the keyring source must offer exactly $KR, offered ${#offered[@]} package(s)"; exit 1; }

echo "  installing $KR"
if ! pacman -S --noconfirm "$KR" > "$W/inst.log" 2>&1; then
  echo "  !! installing $KR failed:"; sed 's/^/    /' "$W/inst.log"; exit 1
fi
pacman -Q "$KR" | sed 's/^/  installed: /'

echo
echo "--- B) the three files, where pacman-key looks for them ---"
for f in qmdmm.gpg qmdmm-trusted qmdmm-revoked; do
  [ -f "$KEYDIR/$f" ] || { echo "  !! $KR did not install $KEYDIR/$f"; exit 1; }
  printf '    %-56s %6s bytes  mode %s\n' "$KEYDIR/$f" "$(wc -c < "$KEYDIR/$f" | tr -d ' ')" \
         "$(stat -c '%a' "$KEYDIR/$f")"
done
# qmdmm.gpg has to BE this line's published key file. A package built from
# another line's key would install, populate, and leave the consumer trusting a
# key that does not sign the repository it is pointed at - and every reading
# after this one would fail for a reason that names the repository.
fetch "$PAGES/keys/$LINE/qmdmm-packages.gpg" "$W/packages.gpg"
if ! cmp -s "$W/packages.gpg" "$KEYDIR/qmdmm.gpg"; then
  echo "  !! the package's qmdmm.gpg is not the published key file for $LINE"
  exit 1
fi
pkgsub=$(live_sub_fpr "$KEYDIR/qmdmm.gpg")
pubsub=$(live_sub_fpr "$W/packages.gpg")
echo "  qmdmm.gpg == keys/$LINE/qmdmm-packages.gpg   live subkey ...${pubsub: -16}"
[ -n "$pkgsub" ] || { echo "  !! the keyring's key file carries no usable subkey"; exit 1; }
[ "$pkgsub" = "$pubsub" ] || { echo "  !! the keyring and the site disagree about the live subkey"; exit 1; }
# -trusted names the root, which is what makes the line's subkey signatures
# acceptable. mkkeyring-pac.sh writes it and explains why it is the primary.
printf '%s:4:\n' "$ROOT_FPR" > "$W/expected-trusted"
cmp -s "$W/expected-trusted" "$KEYDIR/qmdmm-trusted" \
  || { echo "  !! $KEYDIR/qmdmm-trusted is not '$ROOT_FPR:4:'"; sed 's/^/    | /' "$KEYDIR/qmdmm-trusted"; exit 1; }
echo "  qmdmm-trusted names the root, as the package is built to do"
# Present even when empty, which is the state before a line's first rotation.
grep -vE '^$' "$KEYDIR/qmdmm-revoked" | grep -vE '^[0-9A-F]{40}$' >/dev/null && {
  echo "  !! $KEYDIR/qmdmm-revoked carries something that is not a fingerprint"
  sed 's/^/    | /' "$KEYDIR/qmdmm-revoked"; exit 1; }
echo "  qmdmm-revoked: $(grep -cvE '^$' "$KEYDIR/qmdmm-revoked" || true) retired subkey fingerprint(s)"

echo
echo "--- C) CONTROL: the day-to-day source, with --populate NOT run -> must be refused ---"
# The day-to-day source is added now and not before, and the reason is measured
# rather than tidy: a stanza with `SigLevel = Required DatabaseRequired` in the
# same file as the ones above makes the FIRST `pacman -Sy` fail as a whole - the
# database nobody can verify takes the sync down with it - so the bootstrap
# stanza and the day-to-day stanza cannot be read in one pass. This is the step
# an actual user walks, in the order they walk it.
cat >> /etc/pacman.conf <<EOF

[$REPO]
SigLevel = Required DatabaseRequired
Server = $PAGES/$LINE/$VERSION
EOF
if pacman -Sy --noconfirm > "$W/neg.log" 2>&1; then
  echo "  !! pacman accepted the day-to-day source with nothing trusted"
  sed 's/^/    /' "$W/neg.log"; exit 1
fi
echo "  OK: refused, and the files being on disk changed nothing"
grep -iE 'invalid or corrupted|unknown key|signature|error' "$W/neg.log" | head -4 | sed 's/^/    /' || true

echo
echo "--- D) pacman-key --populate qmdmm, then the same source again ---"
pacman-key --populate qmdmm 2>&1 | sed 's/^/  /'
rm -rf /var/lib/pacman/sync/*
if ! pacman -Sy --noconfirm > "$W/sy2.log" 2>&1; then
  echo "  !! pacman -Sy still refuses the day-to-day source:"; sed 's/^/    /' "$W/sy2.log"; exit 1
fi
mapfile -t day < <(pacman -Sl "$REPO" 2>/dev/null | awk '{print $2}' | sort -u || true)
echo "  the day-to-day source offers: ${day[*]:-<none>}"
[ "${#day[@]}" -ge 1 ] || { echo "  !! --populate left the line unreadable"; exit 1; }
echo "  OK: the keyring package plus one command is the whole bootstrap"

echo
echo "=== B/keyring-package (pacman) $LINE $VERSION: PASS ==="
