#!/usr/bin/env bash
#
# Stage C for the Fedora line, in one file: bring the image up to date and
# install a plain build toolchain, publish the packages as a local repository,
# install the dev package and audit the dependency set, report what installing
# it dragged in, and fetch the QMdmm sources the consumer project builds. See
# dev-deb.sh for what stage C asks and why the toolchain is deliberately plain.
set -euxo pipefail

"$(dirname "$0")/base-image-rpm.sh" \
  git ca-certificates gcc-c++ make cmake ninja-build createrepo_c binutils

createrepo_c pkgs
printf '[qmdmm-local]\nname=QMdmm local\nbaseurl=file://%s/pkgs\nenabled=1\ngpgcheck=0\n' \
  "$PWD" > /etc/yum.repos.d/qmdmm-local.repo
cat /etc/yum.repos.d/qmdmm-local.repo

dev=$(awk -F'\t' -v s="$DIST_SFX_DEV" '$1 ~ s"$" { print $1 }' pkgs/MANIFEST.tsv)
echo "dev package: $dev"
# Installing the dev package by name only succeeds if it declares its own
# runtime, dev-common and Qt dependencies - which is the point.
dnf install -y "$dev"
if dnf check --dependencies > /tmp/dnfcheck.log 2>&1; then
  echo 'dnf check: clean'
else
  cat /tmp/dnfcheck.log
  if grep -qE 'qmdmm|libQt6|qt6-' /tmp/dnfcheck.log; then
    echo '::error::dnf reports unsatisfied dependencies for a QMdmm/Qt package'
    exit 1
  fi
  echo '(dnf check reported unrelated issues; not caused by this package)'
fi
{
  echo '### Dev install: dependency audit'
  echo
  echo '```'
  cat /tmp/dnfcheck.log
  echo '```'
} >> "$GITHUB_STEP_SUMMARY"

{
  echo '### Everything present after installing only the dev package'
  echo
  echo '```'
  rpm -qa --qf '%{NAME}\t%{VERSION}\n' | sort
  echo '```'
} >> "$GITHUB_STEP_SUMMARY"

git init qmdmm-src
git -C qmdmm-src remote add origin "$QMDMM_REPO"
git -C qmdmm-src fetch --depth 1 origin "$QMDMM_REF"
git -C qmdmm-src checkout --detach FETCH_HEAD
