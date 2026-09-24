#!/usr/bin/env bash
#
# Stage C for the Debian line, in one file: bring the image up to date and
# install a plain build toolchain, publish the packages as a local repository,
# install the dev package and repair the dependency set, report what installing
# it dragged in, and fetch the QMdmm sources the consumer project builds.
#
# A *clean* container again, and then the smallest set a user would already have
# before trying to build a GUI application. Every Qt dependency and QMdmm itself
# has to arrive through the dev package under test - that is what stage C asks.
set -euxo pipefail

"$(dirname "$0")/base-image-deb.sh" \
  git ca-certificates build-essential cmake ninja-build dpkg-dev apt-utils binutils

cd pkgs
dpkg-scanpackages -m . > Packages
apt-ftparchive release . > Release
echo "deb [trusted=yes] file://$PWD ./" > /etc/apt/sources.list.d/qmdmm-local.list
cd ..
apt-get update

dev=$(awk -F'\t' -v s="$DIST_SFX_DEV" '$1 ~ s"$" { print $1 }' pkgs/MANIFEST.tsv)
echo "dev package: $dev"
# Installing the dev package by name only succeeds if it declares its own
# runtime, dev-common and Qt dependencies - which is the point.
apt-get install -y "$dev"
echo '::group::apt-get -f install (repair pass)'
apt-get -f install -y 2>&1 | tee /tmp/repair.log
echo '::endgroup::'
apt-get check
{
  echo '### Dev install: what the repair pass had to add'
  echo
  echo '```'
  grep -E '^(Inst|Conf|Remv|Removing|The following)' /tmp/repair.log \
    || echo '(nothing: the declared dependencies were complete)'
  echo '```'
} >> "$GITHUB_STEP_SUMMARY"

{
  echo '### Everything present after installing only the dev package'
  echo
  echo '```'
  dpkg-query -W -f='${Package}\t${Version}\n' | sort
  echo '```'
} >> "$GITHUB_STEP_SUMMARY"

git init qmdmm-src
git -C qmdmm-src remote add origin "$QMDMM_REPO"
git -C qmdmm-src fetch --depth 1 origin "$QMDMM_REF"
git -C qmdmm-src checkout --detach FETCH_HEAD
