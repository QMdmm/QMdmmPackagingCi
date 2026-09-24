#!/usr/bin/env bash
#
# Stage A for the Arch line, in one file: bring the image up to date and install
# what makepkg expects underneath it, fetch QMdmm at the requested ref, build
# and pack through the recipe in packaging/arch, collect and assert the package.
#
# Arch configures, builds, packs and inspects in one pass inside makepkg, so
# there is no separate configure/build/pack here the way the cpack lines have:
# the recipe is this line's build description, and it is the one thing that
# makes the harness repository's own checkout load-bearing.
set -euxo pipefail

# base-devel is what makepkg expects underneath it (gcc, make, pkgconf,
# fakeroot). Arch keeps a Qt module's development files in the same package as
# its runtime, so there are no -dev names to ask for. pacman-contrib brings
# updpkgsums, which is how the recipe's checksums follow the tarball this run
# produces. No doxygen: the Arch recipe ships no doc component, deliberately.
# The recipe's own make dependencies are named here rather than left to makepkg:
# makepkg runs as a plain user below and must not have to install anything.
"$(dirname "$0")/base-image-pac.sh" \
  base-devel git ca-certificates cmake ninja \
  qt6-base qt6-declarative qt6-websockets qt6-tools pacman-contrib

git init qmdmm-src
git -C qmdmm-src remote add origin "$QMDMM_REPO"
git -C qmdmm-src fetch --depth 1 origin "$QMDMM_REF"
git -C qmdmm-src checkout --detach FETCH_HEAD
echo "QMdmm HEAD: $(git -C qmdmm-src log --oneline -1)"

pkgver=$(sed -n 's/^pkgver=\(.*\)$/\1/p' packaging/arch/PKGBUILD)
mkdir -p arch-build
cp packaging/arch/PKGBUILD packaging/arch/.SRCINFO arch-build/
# The recipe takes a local tarball rather than a codeload download; its NOTES
# say how it was produced. The prefix is what makes the recipe's own
# `cd "$pkgname-$pkgver"` find the extracted tree. The output path is absolute
# on purpose: -C makes it relative to qmdmm-src, not to the workspace the build
# directory lives in.
git -C qmdmm-src archive --format=tar.gz \
  --prefix="qmdmm-6-${pkgver}/" HEAD \
  -o "$PWD/arch-build/qmdmm-6-${pkgver}.tar.gz"
# The committed checksums pin the tarball of the one locally verified build. A
# run packages whatever ref it was handed, so they have to follow the tarball
# that was actually produced.
#
# The recipe pins Release, as a distribution package should; the build type is a
# dial on dispatched runs, and the other lines hand it straight to CMake. It is
# applied to this copy rather than left to diverge, and the assertion is there
# so a recipe that stops pinning it fails loudly instead of quietly building
# something nobody asked for.
grep -q -- '-DCMAKE_BUILD_TYPE=Release' arch-build/PKGBUILD \
  || { echo "::error::the recipe no longer pins CMAKE_BUILD_TYPE=Release"; exit 1; }
sed -i "s/-DCMAKE_BUILD_TYPE=Release/-DCMAKE_BUILD_TYPE=$QMDMM_BUILD_TYPE/" \
  arch-build/PKGBUILD
# makepkg refuses to run as root, and every step of a container job runs as
# root, so both the checksum refresh and the build happen as an ordinary user -
# updpkgsums is a wrapper around makepkg and is not assumed to be any more
# forgiving. Stages B and C go back to root: installing is not building.
useradd -m -s /bin/bash builder
chown -R builder:builder arch-build
su builder -c "cd '$PWD/arch-build' && updpkgsums"
su builder -c "cd '$PWD/arch-build' && makepkg -f --noconfirm"
ls -l arch-build/*.pkg.tar.zst

mkdir -p out
cp -v arch-build/*.pkg.tar.zst out/

# Names are read back out of the packages instead of being assumed: the
# component suffixes are what stages B and C select on. pacman reads the
# metadata straight out of the package file, the same way dpkg-deb and rpm do.
printf 'package\tversion\tfile\n' > out/MANIFEST.tsv
for f in out/*.pkg.tar.zst; do
  info=$(pacman -Qip "$f")
  printf '%s\t%s\t%s\n' \
    "$(sed -n 's/^Name *: *//p' <<<"$info")" \
    "$(sed -n 's/^Version *: *//p' <<<"$info")" \
    "$(basename "$f")" >> out/MANIFEST.tsv
done

{
  echo '### Packages produced by `makepkg`'
  echo
  echo '```'
  cat out/MANIFEST.tsv
  echo '```'
} >> "$GITHUB_STEP_SUMMARY"

missing=''
for suffix in $DIST_EXPECT; do
  awk -F'\t' -v s="$suffix" '$1 ~ s"$" { found = 1 } END { exit !found }' \
    out/MANIFEST.tsv || missing="$missing $suffix"
done
produced=$(awk 'END { print NR - 1 }' out/MANIFEST.tsv)
if [ "$produced" -ne 1 ]; then
  echo "::error::the Arch line produces one package by decision, but $produced were produced"
  exit 1
fi
if [ -n "$missing" ]; then
  echo "::error::missing component package(s) with suffix:$missing"
  exit 1
fi

{
  echo '### Declared dependencies as shipped'
  echo
  for f in out/*.pkg.tar.zst; do
    echo "#### \`$(basename "$f")\`"
    echo '```'
    pacman -Qip "$f" | grep -E '^(Name|Version|Depends On)' || true
    echo '```'
  done
} >> "$GITHUB_STEP_SUMMARY"
