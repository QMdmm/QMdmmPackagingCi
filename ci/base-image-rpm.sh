#!/usr/bin/env bash
#
# Refresh a Fedora container image and install the packages named on the command
# line. See base-image-deb.sh for why the refresh comes first and why each
# caller passes its own list.
#
# install_weak_deps=False on both transactions: a weak dependency that happens
# to be pulled in would be indistinguishable, later on, from something the
# package under test actually requires.
set -euxo pipefail

dnf -y --setopt=install_weak_deps=False upgrade

if [ "$#" -gt 0 ]; then
  dnf install -y --setopt=install_weak_deps=False "$@"
fi
