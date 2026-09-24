#!/usr/bin/env bash
#
# Refresh a Debian container image and install the packages named on the command
# line. Stage A's toolchain step, stage B's inspection tooling and stage C's
# plain compiler all go through this file; the caller owns the list.
#
# The refresh is what everything installed afterwards is measured against: a
# container image is a snapshot, and a stale one muddies the question every
# stage below asks - how much of what lands on the system can be attributed to
# the package under test and its declared dependencies. apt-get dist-upgrade
# rather than upgrade, because the transaction has to stay free to add and
# remove packages, which is what a distribution expects of a system it is about
# to install new software onto.
#
# The list is what keeps the stages apart: A asks for a full toolchain and Qt 6,
# B for binutils and the package tooling, C for nothing but a compiler - the Qt
# development files there have to arrive through the dev package under test.
set -euxo pipefail

apt-get update
DEBIAN_FRONTEND=noninteractive apt-get dist-upgrade -y

if [ "$#" -gt 0 ]; then
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@"
fi
