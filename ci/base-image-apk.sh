#!/usr/bin/env bash
#
# Refresh an Alpine container image and install the packages named on the
# command line. See base-image-deb.sh for why the refresh comes first and why
# each caller passes its own list.
#
# `--available` is apk's dist-upgrade: every package may move to what the
# repositories have now.
set -euxo pipefail

apk update
apk upgrade --available

if [ "$#" -gt 0 ]; then
  apk add --no-cache "$@"
fi
