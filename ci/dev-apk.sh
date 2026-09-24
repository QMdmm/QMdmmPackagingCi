#!/usr/bin/env bash
#
# Stage C for the Alpine line, in one file: bring the image up to date and
# install a plain build toolchain, publish the packages as a local repository,
# install the dev package and audit the dependency set, report what installing
# it dragged in, and fetch the QMdmm sources the consumer project builds. See
# dev-deb.sh for what stage C asks and why the toolchain is deliberately plain.
set -euxo pipefail

# The Alpine equivalent of build-essential. g++ is a package of its own here and
# is not part of gcc: without it CMake finds no CXX compiler at all and fails at
# project(). pkgconf is named because Qt's own CMake files want it, as
# pkg-config is on the Debian line.
"$(dirname "$0")/base-image-apk.sh" \
  git ca-certificates gcc g++ musl-dev make cmake pkgconf binutils

# Same as stage B: the key has to be in place before the repository is, or apk
# rejects the index as UNTRUSTED. See the note there.
install -m 644 "packaging/alpine/$PACKAGER_KEY.rsa.pub" /etc/apk/keys/
echo "file://$PWD/pkgs" >> /etc/apk/repositories
cat /etc/apk/repositories
apk update

dev=$(awk -F'\t' -v s="$DIST_SFX_DEV" '$1 ~ s"$" { print $1 }' pkgs/MANIFEST.tsv)
runtime=$(awk -F'\t' -v s="$DIST_SFX_RUNTIME" '$1 ~ s"$" { print $1 }' pkgs/MANIFEST.tsv)
echo "dev package: $dev"
# Installing the dev package by name only succeeds if it declares its own
# runtime, documentation and Qt dependencies - which is the point. On this line
# that declaration is `depends_dev` in the APKBUILD: abuild's default split
# gives -dev the runtime package and the so: closure of its symlinks, which is
# nothing to compile against.
apk list --installed | sort > /tmp/before.txt
apk add "$dev"
apk list --installed | sort > /tmp/after.txt
grep -qE "^${dev}-[0-9]" /tmp/after.txt \
  || { echo "::error::$dev is not installed"; exit 1; }
# The runtime package has to arrive with it, not have been installed by hand
# above.
grep -qE "^${runtime}-[0-9]" /tmp/after.txt \
  || { echo "::error::$runtime did not come with the dev package"; exit 1; }

{
  echo '### Everything present after installing only the dev package'
  echo
  echo '```'
  # The difference the dev package made to the package set: apk resolves the
  # whole transaction or fails, so the repair pass the Debian line runs
  # afterwards has no counterpart here.
  comm -13 /tmp/before.txt /tmp/after.txt
  echo '```'
  echo
  echo "added: $(comm -13 /tmp/before.txt /tmp/after.txt | wc -l) packages"
  echo "installed in total: $(wc -l < /tmp/after.txt)"
} >> "$GITHUB_STEP_SUMMARY"

git init qmdmm-src
git -C qmdmm-src remote add origin "$QMDMM_REPO"
git -C qmdmm-src fetch --depth 1 origin "$QMDMM_REF"
git -C qmdmm-src checkout --detach FETCH_HEAD
