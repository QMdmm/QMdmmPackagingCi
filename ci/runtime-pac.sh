#!/usr/bin/env bash
#
# Stage B for the Arch line, in one file: install the inspection tooling,
# publish the packages as a local repository, install the runtime package and
# audit the dependency set. See runtime-deb.sh for why stage B starts from a
# clean container and installs by name.
#
# On Arch the same repository serves a narrower purpose than on the other
# lines. There are no inter-component dependencies to resolve, but installing
# from it by name still proves the package is findable and its declared Qt
# dependencies resolvable.
set -euxo pipefail

# binutils is the whole list here: ldd is the assertion and strings is the QML
# check, and repo-add - Arch's counterpart of dpkg-scanpackages and createrepo_c
# - ships with pacman itself.
"$(dirname "$0")/base-image-pac.sh" binutils
command -v ldd

# Arch's repository is built by repo-add, which ships with pacman. The line does
# not sign its package, so this section carries it as optional-and-trusted
# instead of requiring a signature - a decision confined to this one local
# repository, never to the system's own repositories.
repo-add pkgs/qmdmm-local.db.tar.gz pkgs/*.pkg.tar.zst
printf '\n[qmdmm-local]\nSigLevel = Optional TrustAll\nServer = file://%s/pkgs\n' \
  "$PWD" >> /etc/pacman.conf
tail -4 /etc/pacman.conf
pacman -Syu --noconfirm

pkg=$(awk -F'\t' -v s="$DIST_SFX_RUNTIME" '$1 ~ s"$" { print $1 }' pkgs/MANIFEST.tsv)
echo "package: $pkg"
# pacman resolves a whole transaction or refuses it, like dnf, so there is no
# half-installed state to repair and no repair pass here. What carries the claim
# "the declared dependencies were complete" is the database audit: it reports
# dependencies that are not installed for every package on the system, not just
# the one under test.
pacman -S --noconfirm --needed "$pkg"
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
  echo '### Package install: dependency audit'
  echo
  echo '```'
  cat /tmp/depcheck.log
  echo '```'
} >> "$GITHUB_STEP_SUMMARY"
