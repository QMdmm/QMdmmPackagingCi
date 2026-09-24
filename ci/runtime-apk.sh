#!/usr/bin/env bash
#
# Stage B for the Alpine line, in one file: install the inspection tooling,
# publish the packages as a local repository, install the runtime package and
# audit the dependency set. See runtime-deb.sh for why stage B starts from a
# clean container and installs by name.
#
# This is the one line that asks for something the others do not: neither apt
# nor dnf refuses an unsigned local repository, so those lines write
# trusted=yes / gpgcheck=0 and never meet the question. apk does refuse one, and
# abuild offers no way to switch signing off, so the key that signed the index
# has to be in place first.
set -euxo pipefail

# ldd comes from musl-utils here - same criterion as on the glibc lines, a
# different implementation of it - and the QML assertion further down reads a
# binary with `strings` from binutils. git and ca-certificates are for the
# checkout step in the workflow (that action shells out to git); both are
# installed before the install snapshot, so neither can be mistaken for
# something the package dragged in.
"$(dirname "$0")/base-image-apk.sh" binutils musl-utils git ca-certificates
command -v ldd

install -m 644 "packaging/alpine/$PACKAGER_KEY.rsa.pub" /etc/apk/keys/
# The repository is the *parent* of the arch directory: apk appends
# <arch>/APKINDEX.tar.gz itself.
echo "file://$PWD/pkgs" >> /etc/apk/repositories
cat /etc/apk/repositories
apk update

runtime=$(awk -F'\t' -v s="$DIST_SFX_RUNTIME" '$1 ~ s"$" { print $1 }' pkgs/MANIFEST.tsv)
echo "runtime package: $runtime"
# Installing by name only succeeds if the package declares its own dependencies
# - which is the point. apk resolves the whole transaction or fails, unlike apt,
# which will leave a half-configured system for `apt-get -f install` to repair:
# there is nothing to repair here. The second install is idempotent and only
# kept so this step reads like the other rows'.
#
# `apk list` rather than `apk info -e`: apk-tools 3 moved that question to `apk
# list`, and `alpine:latest` can move under this workflow. A file rather than a
# pipe into grep, because with pipefail a grep that exits early can turn a found
# match into a SIGPIPE failure.
apk list --installed | sort > /tmp/before.txt
apk add "$runtime"
apk add "$runtime"
apk list --installed | sort > /tmp/after.txt
grep -qE "^${runtime}-[0-9]" /tmp/after.txt \
  || { echo "::error::$runtime is not installed"; exit 1; }
{
  echo '### Runtime install: what installing it added'
  echo
  echo '```'
  comm -13 /tmp/before.txt /tmp/after.txt
  echo '```'
  echo
  echo "added: $(comm -13 /tmp/before.txt /tmp/after.txt | wc -l) packages"
  echo "installed in total: $(wc -l < /tmp/after.txt)"
} >> "$GITHUB_STEP_SUMMARY"
