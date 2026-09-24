#!/usr/bin/env bash
#
# Stage A for the Alpine line, in one file: bring the image up to date and
# install the packager, put the packager key in place, prepare the recipe and
# the source tarball, build and sign through abuild, collect and assert the
# packages. There is no cpack here - the package comes out of abuild and
# packaging/alpine/APKBUILD - and the repository it produces is a *signed*
# APKINDEX, which is why this workflow holds a packager key at all.
#
# The private key arrives as $PRIVKEY, injected by the workflow from the
# PACKAGER_PRIVKEY secret. The secret's name does not appear here, and neither
# does its value beyond the one file this script writes it to.
set -euxo pipefail

# Deliberately the packager only. The local (proot) verification had to
# pre-install the whole toolchain and call abuild with -d, because proot does
# not emulate the setuid on abuild-sudo; a container is a real root environment
# where that helper works, so `abuild -r` resolves makedepends by itself.
# Pre-installing that closure here would quietly delete the most valuable thing
# this stage verifies.
"$(dirname "$0")/base-image-apk.sh" \
  abuild fakeroot scanelf git ca-certificates openssl tar

# abuild refuses to run as root, and the abuild package already created the
# group its setuid helper authorizes through (gid 300): the group is not created
# here and its gid is not pinned.
adduser -D -G abuild builder
id builder

if [ -z "$PRIVKEY" ]; then
  echo "::error::the PACKAGER_PRIVKEY secret is not set, and abuild cannot sign a package without a key"
  exit 1
fi
priv="/home/builder/.abuild/$PACKAGER_KEY.rsa"
pub="packaging/alpine/$PACKAGER_KEY.rsa.pub"
install -d -m 700 -o builder -g abuild /home/builder/.abuild
printf '%s\n' "$PRIVKEY" > "$priv"
chown builder:abuild "$priv"
chmod 600 "$priv"
# abuild-sign is handed the private key and takes two things from the public
# half: it has to be next to it as <private>.pub, and the signature member it
# writes is named after that file (".SIGN.RSA.<name>"). apk resolves the same
# name in /etc/apk/keys, so the halves have to be a pair *and* the two file
# names have to agree - a mismatch would otherwise only surface two stages later
# as a bare "UNTRUSTED signature". Assert both here, and put the committed
# public half where abuild-sign looks for it.
openssl pkey -in "$priv" -pubout -outform DER \
  | cmp - <(openssl pkey -pubin -in "$pub" -outform DER)
install -m 644 -o builder -g abuild "$pub" "$priv.pub"
# The building container needs it in its trust store as well, and not only the
# consuming ones: `abuild -r` finishes by updating the repository index, and
# `apk index` verifies the signature of every package it indexes. Without the
# key here that last step fails once per package with "UNTRUSTED signature" -
# after the whole build, which is an expensive way to learn that the key was not
# where apk looks.
install -m 644 "$pub" /etc/apk/keys/
# And ask abuild itself. This is the very first thing `abuild -r` does ("check
# early if we have abuild key"), so finding out here costs seconds instead of
# the whole build.
su builder -c "HOME=/home/builder PACKAGER_PRIVKEY=$priv abuild-sign --installed"
echo "the secret and $pub are the same pair, abuild-sign can use them, and apk trusts the key"

install -d -m 755 -o builder -g abuild /home/builder/qmdmm
install -m 644 -o builder -g abuild packaging/alpine/APKBUILD /home/builder/qmdmm/APKBUILD
# A git tree rather than a codeload download: `git archive` is what produces the
# layout abuild looks for, and the prefix has to be $pkgname-$pkgver or abuild
# will not find the directory it expects to unpack into. The clone is kept out
# of the recipe directory on purpose, because abuild unpacks into a `src`
# subdirectory of that one.
git init /home/builder/source
git -C /home/builder/source remote add origin "$QMDMM_REPO"
git -C /home/builder/source fetch --depth 1 origin "$QMDMM_REF"
git -C /home/builder/source checkout --detach FETCH_HEAD
echo "QMdmm HEAD: $(git -C /home/builder/source log --oneline -1)"
pkgver=$(sed -n 's/^pkgver=//p' packaging/alpine/APKBUILD)
git -C /home/builder/source archive --format=tar.gz \
  --prefix="qmdmm-$pkgver/" \
  -o "/home/builder/qmdmm/qmdmm-$pkgver.tar.gz" FETCH_HEAD
chown -R builder:abuild /home/builder/qmdmm
ls -l /home/builder/qmdmm

before=$(sed -n '/^sha512sums=/{n;p;}' /home/builder/qmdmm/APKBUILD)
su builder -c "cd /home/builder/qmdmm && HOME=/home/builder abuild checksum"
after=$(sed -n '/^sha512sums=/{n;p;}' /home/builder/qmdmm/APKBUILD)
{
  echo '### The source pin'
  echo
  echo 'The recipe carries a sha512 pin for the tarball that was verified'
  echo 'locally, and this run packages whatever `QMDMM_REF` points at, so'
  echo 'the tarball is generated here and the pin is re-derived from it.'
  echo 'The pin still does its job: a tarball that is not the one just'
  echo 'generated does not match it.'
  echo
  echo '```'
  echo "committed: $before"
  echo "this run:  $after"
  echo '```'
} >> "$GITHUB_STEP_SUMMARY"
# No -d. It means "do not resolve dependencies" and would short-circuit exactly
# what this stage exists to check; it was only ever needed because proot cannot
# run the setuid helper.
su builder -c "cd /home/builder/qmdmm && HOME=/home/builder PACKAGER_PRIVKEY=/home/builder/.abuild/$PACKAGER_KEY.rsa abuild -r"

# Where abuild put them is discovered rather than assumed: the directory is
# named after the repository the image is pointed at, which is not something to
# guess at from here.
index=$(find /home/builder -name APKINDEX.tar.gz -print -quit)
if [ -z "$index" ]; then
  echo "::error::abuild produced no APKINDEX.tar.gz"
  exit 1
fi
repodir=$(dirname "$index")
echo "repository directory: $repodir"
mkdir -p out
cp -a "$repodir" out/

printf 'package\tversion\tfile\n' > out/MANIFEST.tsv
for f in out/*/*.apk; do
  p=$(tar xzOf "$f" .PKGINFO | sed -n 's/^pkgname = //p')
  v=$(tar xzOf "$f" .PKGINFO | sed -n 's/^pkgver = //p')
  printf '%s\t%s\t%s\n' "$p" "$v" "$(basename "$f")" >> out/MANIFEST.tsv
done

{
  echo '### Packages produced by `abuild -r`'
  echo
  echo '```'
  cat out/MANIFEST.tsv
  echo '```'
} >> "$GITHUB_STEP_SUMMARY"

# Exact names, not suffixes: on Alpine the runtime package is plain `qmdmm`,
# with no Qt generation in it, which makes `qmdmm` a prefix of every other name
# and a suffix match useless.
missing=''
for want in qmdmm qmdmm-dev qmdmm-doc; do
  awk -F'\t' -v n="$want" '$1 == n { found = 1 } END { exit !found }' \
    out/MANIFEST.tsv || missing="$missing $want"
done
if [ -n "$missing" ]; then
  echo "::error::missing package(s):$missing"
  exit 1
fi

# Every package and the index have to be signed by the key committed in
# packaging/alpine: that name is what apk looks up in /etc/apk/keys, so a
# repository signed by anything else is untrusted by construction.
expected=".SIGN.RSA.$PACKAGER_KEY.rsa.pub"
for f in out/*/*.apk out/*/APKINDEX.tar.gz; do
  # The listing goes to a file, and only the signature members are printed: the
  # documentation package has thousands of members, and a listing that big does
  # not fit in a pipe buffer.
  tar tzf "$f" > /tmp/members.txt
  echo "### $(basename "$f"): $(wc -l < /tmp/members.txt) members, signature members:"
  grep '^\.SIGN\.' /tmp/members.txt | sed -n 's/^/  /' || true
  # Read from the file rather than piping the listing into `grep -q`: `grep -q`
  # exits on its first match, which leaves the writer holding a pipe with nobody
  # reading it - SIGPIPE, and `set -o pipefail` turns that into a failed step for
  # a package that is signed perfectly well. It only shows up on the packages
  # whose listing exceeds the pipe buffer, which is why it would look like a
  # signature problem.
  if ! grep -qxF "$expected" /tmp/members.txt; then
    echo "::error::$(basename "$f") does not carry $expected"
    exit 1
  fi
done

{
  echo '### Declared metadata as shipped'
  echo
  for f in out/*/*.apk; do
    echo "#### \`$(basename "$f")\`"
    echo '```'
    tar xzOf "$f" .PKGINFO \
      | grep -E '^(pkgname|pkgver|pkgdesc|depend|provides|size|origin) = ' || true
    echo '```'
  done
} >> "$GITHUB_STEP_SUMMARY"
