#!/usr/bin/env bash
#
# Refresh an rpm container image and install the packages named on the command
# line. See base-image-deb.sh for why the refresh comes first and why each
# caller passes its own list.
#
# install_weak_deps=False on both transactions: a weak dependency that happens
# to be pulled in would be indistinguishable, later on, from something the
# package under test actually requires.
set -euxo pipefail

dnf -y --setopt=install_weak_deps=False upgrade

# Enterprise Linux leaves CRB (CodeReady Builder) disabled, and the Fedora line
# does not have such a repository at all. Stage A's list needs it: on
# rockylinux/rockylinux:10, ninja-build and doxygen are both only in crb, while
# almalinux:10 happens to have them enabled - so before this, the two EL rows
# were not interchangeable and the Rocky one could not install its toolchain.
#
# Enabled after the upgrade and before the install, on purpose: the upgrade
# should still be the distribution's own repositories, so a build image does not
# quietly acquire CRB builds of packages nobody asked for. Only the caller's
# explicit install list can draw from CRB.
#
# The id is tried rather than assumed - it differs across EL rebuilds and
# versions ("crb", "powertools", the full codeready-builder-*-rpms name), and a
# Fedora image has none of them. This is a no-op where it does not apply.
for repo in crb powertools codeready-builder-for-rhel-10-x86_64-rpms \
            codeready-builder-for-rhel-9-x86_64-rpms; do
  if dnf -q repolist --all 2>/dev/null | awk '{print $1}' | grep -qx "$repo"; then
    dnf install -y --setopt=install_weak_deps=False dnf-plugins-core
    dnf config-manager --set-enabled "$repo"
    echo "enabled repository: $repo"
  fi
done

if [ "$#" -gt 0 ]; then
  dnf install -y --setopt=install_weak_deps=False "$@"
fi
