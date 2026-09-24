#!/usr/bin/env bash
#
# Stage C for the Arch line, in one file: bring the image up to date and install
# a plain build toolchain, publish the packages as a local repository, install
# the dev package and audit the dependency set, report what installing it
# dragged in, and fetch the QMdmm sources the consumer project builds. See
# dev-deb.sh for what stage C asks and why the toolchain is deliberately plain.
set -euxo pipefail

# base-devel is the Arch answer to "a plain build toolchain", the same role
# build-essential and gcc-c++ play on the other lines.
"$(dirname "$0")/base-image-pac.sh" \
  base-devel git ca-certificates cmake ninja binutils

repo-add pkgs/qmdmm-local.db.tar.gz pkgs/*.pkg.tar.zst
printf '\n[qmdmm-local]\nSigLevel = Optional TrustAll\nServer = file://%s/pkgs\n' \
  "$PWD" >> /etc/pacman.conf
tail -4 /etc/pacman.conf
pacman -Syu --noconfirm

# The same package the runtime stage installs: Arch splits nothing, so this
# line's runtime package *is* its dev package. What is tested here is therefore
# not "a second package resolves" but "one package is enough to build against" -
# the headers and the CMake package it carries have to work with nothing but
# what it dragged in.
pkg=$(awk -F'\t' -v s="$DIST_SFX_DEV" '$1 ~ s"$" { print $1 }' pkgs/MANIFEST.tsv)
echo "package: $pkg"
pacman -S --noconfirm --needed "$pkg"
# Same audit as the runtime stage, for the same reason: pacman either resolves
# the transaction or refuses it, so what is left to check is whether anything on
# the system is unsatisfied.
if pacman -Dk > /tmp/depcheck.log 2>&1; then
  echo 'pacman -Dk: no missing dependencies'
else
  cat /tmp/depcheck.log
  if grep -qE 'qmdmm|qt6-' /tmp/depcheck.log; then
    echo '::error::pacman reports unsatisfied dependencies for a QMdmm/Qt package'
    exit 1
  fi
  echo '(pacman -Dk reported unrelated issues; not caused by this package)'
fi
{
  echo '### Dev install: dependency audit'
  echo
  echo '```'
  cat /tmp/depcheck.log
  echo '```'
} >> "$GITHUB_STEP_SUMMARY"

{
  echo '### Everything present after installing only the dev package'
  echo
  echo '```'
  pacman -Q | sort
  echo '```'
} >> "$GITHUB_STEP_SUMMARY"

git init qmdmm-src
git -C qmdmm-src remote add origin "$QMDMM_REPO"
git -C qmdmm-src fetch --depth 1 origin "$QMDMM_REF"
git -C qmdmm-src checkout --detach FETCH_HEAD
