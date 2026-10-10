#!/usr/bin/env bash
#
# Stage B for the pacman format: the **pacman** consumer.
#
# Named by consumer on purpose. pacman is the program that reads what stage S
# produced (a database plus its detached signature); the format is the tarball
# inside. Arch and Manjaro both use this script.
#
# Consumer-side check, run inside a clean archlinux:base / manjarolinux:base
# container. Public keys come from Pages only; this holds no secret at all.
#
#   env: PAGES, LINE, VERSION, ROOT_FPR, EXPECT_SHA, PKGS (optional)
#
# What is checked:
#   A. the trust bootstrap this line has: read the keyring source, install the
#      keyring PACKAGE, `pacman-key --populate qmdmm` -> the day-to-day source
#      must be read and a package installed from it
#   B. take the line's operational key back OUT of the trust store -> the same
#      source must be refused
#
# A is what the keyring package is for. What used to be two commands run by hand
# against a key file fetched from Pages (`pacman-key --add` + `--lsign-key`) is
# now one install and one command, and the trust travels as a published artefact
# instead of living on whichever machine happened to run those two commands.
#
# A therefore overlaps the keyring cell, and that is the trade rather than an
# oversight: pacman cannot be pointed at a key file - no `Signed-By` as on deb, no
# `gpgkey=` as on rpm - so the published key material is unusable until someone
# types those two commands, and a consumer cell that typed them would be testing a
# route this line does not document. The cost is that a broken keyring source
# reddens both cells and the pair no longer says which one broke; what it buys is
# the reading the keyring cell does not take - that the packages the DAY-TO-DAY
# source serves are the ones this run built, install, and come from that source.
#
# B is NOT the check it replaces, and the difference is measured rather than
# editorial. The old B claimed that with only the ROOT key locally signed the
# database must be refused, on the grounds that otherwise "the per-line subkey
# would prove nothing here". That claim is false on this line: the line keys are
# SUBKEYS of the root key, so locally signing the root makes its subkeys'
# signatures valid - with the root signed and the subkey present, `pacman -Sy`
# accepts the database. The old check only went red because it also DELETED the
# subkey, so what it was reading was the deletion and not the trust. pacman has
# no per-repository key scope (FINDINGS.md §6), so "only this line's key may sign
# this line's database" is not a property this line can assert at all; what it
# can assert is that the database stops being acceptable the moment the line's
# key is gone, which is what B below does.
set -euo pipefail

PAGES="${PAGES:?}"; LINE="${LINE:?}"; VERSION="${VERSION:?}"
ROOT_FPR="${ROOT_FPR:?}"; EXPECT_SHA="${EXPECT_SHA:?}"
PKGS="${PKGS:-}"
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
mkdir -p "$W/keys"
source "$(dirname "$0")/lib-site.sh"

# The database stage S builds is named after the repository, and the published
# one is called `qmdmm` - so the section name is fixed. The lab called this
# `lab`; sign-repo-pac.sh, lib-site.sh's fetch_row_metadata and this section
# have to carry the same string.
REPO=qmdmm
# The keyring source this line publishes. Its section name, its database's name
# and the name of the package inside it are one string, deliberately - pacman
# asks for `<section>.db`, so nothing else could hold them together
# (mkkeyring-pac.sh's header). The trust bootstrap is the only thing it carries.
KR=qmdmm-keyring
# Where pacman-key reads keyrings from, compiled into it as
# KEYRING_IMPORT_DIR. It is a literal here because this is the path inside the
# consumer's container; the published side (mkkeyring-pac.sh) installs into the
# same one.
KEYDIR=/usr/share/pacman/keyrings

echo "=== B/pacman $LINE $VERSION ==="
echo "  $(os_name)"
echo "  pacman: $(pacman --version | head -1)"

echo
echo "--- mirrorlist (left alone unless it has no server at all) ---"
# Only fill an empty mirrorlist. Overwriting it unconditionally would point
# Manjaro at Arch's mirrors, where none of Manjaro's own packages exist.
if ! grep -qE '^\s*Server' /etc/pacman.d/mirrorlist; then
  echo 'Server = https://geo.mirror.pkgbuild.com/$repo/os/$arch' > /etc/pacman.d/mirrorlist
fi
grep -E '^\s*Server' /etc/pacman.d/mirrorlist | head -3 | sed 's/^/  /'

echo
echo "--- tooling ---"
# Asking for `archlinux-keyring` by name would fail on the Manjaro row (that
# package does not exist there), and pacman installs all-or-nothing, so the
# failure would have taken gnupg and curl down with it.
pacman_tools
command -v gpg  >/dev/null || { echo "  !! gpg is missing"; exit 1; }
command -v curl >/dev/null || { echo "  !! curl is missing"; exit 1; }
assert_tls "$PAGES/publish.json" || exit 1
# Locally signing a key has to SIGN with the local keyring's master key, and
# `pacman-key --populate` is exactly that - it imports the package's keyring and
# then runs the local signing over `-trusted` (lsign_keys in pacman-key) - so the
# question is not "is there a keyring" - Arch's base image ships one, filled
# with the distribution's public keys and with no secret key at all. Without
# this, the first command that has to sign dies with "There is no secret key
# available to sign with", which is a message about the keyring and looks nothing
# like the actual problem: a container that has never needed to sign anything.
if ! gpg --homedir /etc/pacman.d/gnupg --list-secret-keys 2>/dev/null | grep -q '^sec'; then
  echo "  (the pacman keyring has no secret key; creating one)"
  pacman-key --init
  gpg --homedir /etc/pacman.d/gnupg --list-secret-keys 2>/dev/null | grep -q '^sec' \
    || { echo "  !! pacman-key --init did not produce a key this keyring can sign with"; exit 1; }
fi
echo "  pacman keyring can sign: yes"
echo "  gpg:   $(command -v gpg)"
echo "  curl:  $(command -v curl)"
echo
echo "--- wait for the site to serve this run's publish ---"
wait_for_publish "$PAGES" "$EXPECT_SHA"

echo
echo "--- which key this line's source is signed by, from Pages ---"
# Not what grants the trust - the keyring package does that, above - but the
# fingerprint the trust store has to end up accepting, so that B can take exactly
# that key back out. Read off the published bytes rather than inferred from what
# the install put on disk, because those two disagreeing is itself the failure
# this cell exists to catch.
fetch "$PAGES/keys/qmdmm-root.gpg"          "$W/keys/root.gpg"
fetch "$PAGES/keys/$LINE/qmdmm-packages.gpg" "$W/keys/packages.gpg"

echo
echo "--- the keys really are what the design says they are ---"
rootfpr=$(key_fpr "$W/keys/root.gpg")
nsub=$(count_subkeys "$W/keys/root.gpg")
echo "  root key file:  $rootfpr   subkeys: $nsub"
[ "$rootfpr" = "$ROOT_FPR" ] || { echo "  !! root fingerprint is not $ROOT_FPR"; exit 1; }
[ "$nsub" = 0 ] || { echo "  !! the root key file carries subkeys; it must carry none"; exit 1; }
sub=$(live_sub_fpr "$W/keys/packages.gpg")
echo "  packages key:   ${sub:-<none>}   (this line's operational subkey)"
[ -n "$sub" ] || { echo "  !! the packages key file carries no usable subkey"; exit 1; }
# The USABLE one, not the first one. After a rotation this file is
# root + outgoing[revoked] + incoming, and B has to take back out the subkey that
# actually signs the day-to-day database: deleting the outgoing one would leave
# the database readable by the incoming one and turn B into a passing no-op.
dead=$(dead_subkeys "$W/keys/packages.gpg")
if [ "$dead" != 0 ]; then
  echo "  (+$dead revoked subkey in the same file: this line has been rotated,"
  echo "   so the subkey B removes is the live one, not the first one)"
fi
echo "  OK: root and operational keys are different keys"

echo
echo "--- A) the bootstrap this line has: the keyring package, then populate ---"
# The stanza a user writes by hand on this line, and it checks nothing: a machine
# that has never trusted anything has nothing to check a first package against.
# What ends that state is the command after the install - which is what the
# keyring package exists for - and the `pacman -Sy` that follows it is the
# reading with teeth, because the database it reads is signed by this line's
# operational subkey and a substituted keyring would leave it unreadable.
#
# The two stanzas go in at different times on purpose, and that is measured
# rather than tidy: a stanza carrying `SigLevel = Required DatabaseRequired` in
# the same file as the bootstrap one makes the FIRST `pacman -Sy` fail as a whole
# - the database nobody can verify yet takes the sync down with it - so the
# day-to-day source is appended only once the trust store can check it.
cat >> /etc/pacman.conf <<EOF

[$KR]
SigLevel = Never
Server = $PAGES/$LINE-keyring/$VERSION
EOF
echo "  | [$KR]  SigLevel = Never  Server = $PAGES/$LINE-keyring/$VERSION"
if ! pacman -Sy --noconfirm > "$W/boot.log" 2>&1; then
  echo "  !! pacman -Sy refused the keyring source:"; sed 's/^/    /' "$W/boot.log"; exit 1
fi
grep -iE "$KR|error" "$W/boot.log" | sed 's/^/    /' || true
echo "  installing $KR"
if ! pacman -S --noconfirm "$KR" > "$W/keyring.log" 2>&1; then
  echo "  !! installing $KR failed:"; sed 's/^/    /' "$W/keyring.log"; exit 1
fi
pacman -Q "$KR" | sed 's/^/  installed: /'
# "The package installed" and "the keyring is where pacman-key looks" are
# different readings, and only the second one is what populate needs.
for f in qmdmm.gpg qmdmm-trusted qmdmm-revoked; do
  [ -f "$KEYDIR/$f" ] || { echo "  !! $KR did not install $KEYDIR/$f"; exit 1; }
done
echo "  the three keyring files are in place under $KEYDIR"
pacman-key --populate qmdmm 2>&1 | sed 's/^/    /'
cat >> /etc/pacman.conf <<EOF

[$REPO]
SigLevel = Required DatabaseRequired
Server = $PAGES/$LINE/$VERSION
EOF
echo "  | [$REPO]  Server = $PAGES/$LINE/$VERSION"
if ! pacman -Sy --noconfirm > "$W/update.log" 2>&1; then
  echo "  !! pacman -Sy refused the database:"; sed 's/^/    /' "$W/update.log"; exit 1
fi
grep -iE "$REPO|qmdmm|error|warning" "$W/update.log" | sed 's/^/    /' || true

mapfile -t found < <(pacman -Sl "$REPO" 2>/dev/null | awk '{print $2}' | sort -u || true)
echo "  packages the database serves: ${found[*]:-<none>}"
[ "${#found[@]}" -ge 1 ] || { echo "  !! the source served no qmdmm package at all"; exit 1; }
if [ -n "$PKGS" ]; then
  assert_same_set "packages served vs built" "$(built_packages "$PKGS")" "$(printf '%s\n' "${found[@]}")"
fi

mapfile -t runtime < <(printf '%s\n' "${found[@]}" | runtime_packages)
[ "${#runtime[@]}" -ge 1 ] || { echo "  !! no runtime package to install"; exit 1; }
echo "  installing: ${runtime[*]}"
pacman -S --noconfirm "${runtime[@]}" > "$W/install.log" 2>&1 || {
  echo "  !! install failed:"; sed 's/^/    /' "$W/install.log"; exit 1; }
for p in "${runtime[@]}"; do
  pacman -Q "$p" | sed 's/^/  installed: /'
done
echo "  where pacman took it from:"
pacman -Qi "${runtime[0]}" | grep -iE '^(Version|Repository|Packager)' | sed 's/^/    /' || true

echo
echo "--- B) take this line's key back out of the trust store -> must be refused ---"
# What has teeth here is the key's ABSENCE. Not "only the root was signed": on
# this line the root's subkeys inherit its trust, so a keyring with the root
# locally signed and the subkey still present accepts the database (see the
# header - that is what the check this replaces was misreading).
pacman-key --delete "$sub" >/dev/null 2>&1 || true
rm -rf /var/lib/pacman/sync/*
if pacman -Sy --noconfirm > "$W/neg.log" 2>&1; then
  echo "  !! pacman accepted the database with the key that signed it removed"
  sed 's/^/    /' "$W/neg.log"; exit 1
fi
echo "  OK: refused, as it must be"
grep -iE 'invalid or corrupted|unknown key|signature|error' "$W/neg.log" | head -4 | sed 's/^/    /' || true

echo
echo "=== B/pacman $LINE $VERSION: PASS ==="
