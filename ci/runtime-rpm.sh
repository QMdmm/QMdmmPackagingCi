#!/usr/bin/env bash
#
# Stage B for the Fedora line, in one file: install the inspection tooling,
# publish the packages as a local repository, install the runtime package and
# audit the dependency set. See runtime-deb.sh for why stage B starts from a
# clean container and installs by name.
#
# dnf resolves the whole transaction or fails, so there is no half-installed
# state to repair here: the "repair" pass is a second, idempotent install plus a
# dependency audit.
set -euxo pipefail

"$(dirname "$0")/base-image-rpm.sh" binutils createrepo_c
command -v ldd

createrepo_c pkgs
printf '[qmdmm-local]\nname=QMdmm local\nbaseurl=file://%s/pkgs\nenabled=1\ngpgcheck=0\n' \
  "$PWD" > /etc/yum.repos.d/qmdmm-local.repo
cat /etc/yum.repos.d/qmdmm-local.repo

runtime=$(awk -F'\t' -v s="$DIST_SFX_RUNTIME" '$1 ~ s"$" { print $1 }' pkgs/MANIFEST.tsv)
echo "runtime package: $runtime"
dnf install -y "$runtime"
dnf install -y "$runtime"
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
  echo '### Runtime install: dependency audit'
  echo
  echo '```'
  cat /tmp/dnfcheck.log
  echo '```'
} >> "$GITHUB_STEP_SUMMARY"
