#!/usr/bin/env bash
#
# Stage B for the Debian line, in one file: install the inspection tooling,
# publish the packages as a local repository, install the runtime package and
# repair the dependency set.
#
# A *clean* container is the point of stage B: with the toolchain and the Qt
# development packages still installed, a missing runtime dependency would be
# masked by them and "minimal but complete" could not be verified at all. The
# packages are installed from the local repository rather than by file path,
# because that is the only way the declared inter-component dependencies
# (qmdmm-6-dev -> qmdmm-6 + qmdmm-common-dev) are actually resolved instead of
# being sidestepped.
set -euxo pipefail

"$(dirname "$0")/base-image-deb.sh" binutils dpkg-dev apt-utils
command -v ldd

cd pkgs
dpkg-scanpackages -m . > Packages
apt-ftparchive release . > Release
echo "deb [trusted=yes] file://$PWD ./" > /etc/apt/sources.list.d/qmdmm-local.list
cd ..
apt-get update

runtime=$(awk -F'\t' -v s="$DIST_SFX_RUNTIME" '$1 ~ s"$" { print $1 }' pkgs/MANIFEST.tsv)
echo "runtime package: $runtime"
apt-get install -y "$runtime"
# apt is the one package manager that leaves a half-installed system behind, so
# this line is the one with something to repair.
echo '::group::apt-get -f install (repair pass)'
apt-get -f install -y 2>&1 | tee /tmp/repair.log
echo '::endgroup::'
apt-get check
{
  echo '### Runtime install: what the repair pass had to add'
  echo
  echo '```'
  grep -E '^(Inst|Conf|Remv|Removing|The following)' /tmp/repair.log \
    || echo '(nothing: the declared dependencies were complete)'
  echo '```'
} >> "$GITHUB_STEP_SUMMARY"
