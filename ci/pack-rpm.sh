#!/usr/bin/env bash
#
# Stage A for the Fedora line, in one file: bring the image up to date and
# install the toolchain and Qt 6, fetch QMdmm at the requested ref, configure,
# build, pack with cpack, collect and assert the packages. Fedora describes its
# packages with cpack options from the QMdmm tree itself, so nothing here reads
# the harness repository any more than the unconditional checkout does.
#
# The build type is a dial on dispatched runs (`QMDMM_BUILD_TYPE`) and goes
# straight to CMake, as a distribution package should.
set -euxo pipefail

"$(dirname "$0")/base-image-rpm.sh" \
  git ca-certificates gcc-c++ make cmake ninja-build rpm-build rpm \
  qt6-qtbase-devel qt6-qtwebsockets-devel qt6-qtdeclarative-devel \
  qt6-qttools-devel doxygen graphviz

git init qmdmm-src
git -C qmdmm-src remote add origin "$QMDMM_REPO"
git -C qmdmm-src fetch --depth 1 origin "$QMDMM_REF"
git -C qmdmm-src checkout --detach FETCH_HEAD
echo "QMdmm HEAD: $(git -C qmdmm-src log --oneline -1)"

# /usr is where a distribution package installs: it decides both the on-disk
# layout and the baked-in QMDMM_CONFIGURATION_PREFIX.
cmake -S qmdmm-src -B build -G Ninja \
  -DCMAKE_BUILD_TYPE="$QMDMM_BUILD_TYPE" \
  -DCMAKE_INSTALL_PREFIX=/usr \
  -DBUILD_TESTING=OFF \
  -DQMDMM_EXPORT_PRIVATE=NO
cmake --build build --parallel

# The native generator is what stages B and C consume. The daily run asks for
# TGZ in the same invocation as well: an archive is the install shape that asks
# nothing of a distribution - the same installed tree, without the package
# metadata - and it is the one product every line here can make with cpack
# alone. `PACK_ARCHIVE` is set by packaging-smoke.yml and by nobody else, so a
# release's artifacts do not change, and the archive is collected into
# `out-archive` rather than `out`: stages B and C download `out` and must keep
# seeing exactly the packages. The other archives the project also configures
# (7Z/TXZ/TZST/ZIP) are not asked for - one format is the product, not five.
generators='RPM'
if [ "${PACK_ARCHIVE:-0}" = 1 ]; then
  generators='RPM;TGZ'
fi
(cd build && cpack -G "$generators")

mkdir -p out
cp -v build/*.rpm out/
if [ "${PACK_ARCHIVE:-0}" = 1 ]; then
  mkdir -p out-archive
  cp -v build/*.tar.gz out-archive/
fi

# Names are read back out of the packages instead of being assumed: the
# component suffixes are what stages B and C select on.
printf 'package\tversion\tfile\n' > out/MANIFEST.tsv
for f in out/*.rpm; do
  printf '%s\t%s\t%s\n' \
    "$(rpm -qp --qf '%{NAME}' "$f")" "$(rpm -qp --qf '%{VERSION}' "$f")" "$(basename "$f")" \
    >> out/MANIFEST.tsv
done

{
  echo '### Packages produced by `cpack -G rpm`'
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
if [ -n "$missing" ]; then
  echo "::error::missing component package(s) with suffix:$missing"
  exit 1
fi

{
  echo '### Declared dependencies as shipped'
  echo
  for f in out/*.rpm; do
    echo "#### \`$(basename "$f")\`"
    echo '```'
    rpm -qpi "$f" | grep -E '^(Name|Version|Requires)' || true
    echo '```'
  done
} >> "$GITHUB_STEP_SUMMARY"
