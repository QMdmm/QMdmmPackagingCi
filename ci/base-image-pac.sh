#!/usr/bin/env bash
#
# Refresh an Arch container image and install the packages named on the command
# line. See base-image-deb.sh for why the refresh comes first and why each
# caller passes its own list.
#
# Arch has one rolling repository set, so -Syu is the whole "bring it up to
# date" story - there is no sid/stable split to choose between. The keyring goes
# first because an image that has aged cannot verify today's packages, and the
# mirrorlist is pinned to the canonical geo mirror so the job does not depend on
# which entries the image happens to ship enabled.
set -euxo pipefail

echo 'Server = https://geo.mirror.pkgbuild.com/$repo/os/$arch' \
  > /etc/pacman.d/mirrorlist
pacman -Sy --noconfirm --needed archlinux-keyring
pacman -Syu --noconfirm

if [ "$#" -gt 0 ]; then
  pacman -S --noconfirm --needed "$@"
fi
