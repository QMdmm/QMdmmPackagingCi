#!/usr/bin/env bash
#
# Stage A for the macOS line, in one file: configure against the *official* Qt
# the workflow installed, build, pack a .dmg with cpack, then assert the shape
# of what came out. It is the same stage as the four Linux lines with the same
# skeleton - fetch the ref, configure with a pinned install prefix, build, pack,
# collect - and only these differ:
#
#   the Qt it builds against
#     The Linux lines take Qt from their distribution's packages. This line
#     cannot: a QMdmm6.app that carries its own Qt inside it has to be built
#     against an archive whose frameworks are relocatable, and Homebrew's Qt is
#     not - its QML plugins are symlinks into the Cellar, so copying them into a
#     bundle leaves them dangling. So the workflow installs the official archive
#     with install-qt-action and hands its root down as QT_ROOT_DIR.
#
#   five flags a distribution package does not need
#     CMAKE_PREFIX_PATH points at that archive; CMAKE_IGNORE_PREFIX_PATH keeps
#     /opt/homebrew - which is where this image's cmake and ninja come from -
#     out of the *search* path, so no package of the harness sneaks into the
#     bundle's dependencies; CMAKE_OSX_ARCHITECTURES makes one universal product
#     instead of an arch matrix; CMAKE_OSX_DEPLOYMENT_TARGET is read out of the
#     archive's own QtCore instead of being left to the host SDK, which is what
#     the bundle then declares; and the install prefix is not /usr, because a
#     .dmg is not installed by a package manager.
#
#   the generator
#     DragNDrop, which is what produces the .dmg - and is only configured at all
#     when QMDMM_MACOS_APP_BUNDLE is ON, which is its default. A cpack run that
#     cannot find the generator is therefore "the bundle shape did not happen",
#     not a missing tool.
set -euxo pipefail

git init qmdmm-src
git -C qmdmm-src remote add origin "$QMDMM_REPO"
git -C qmdmm-src fetch --depth 1 origin "$QMDMM_REF"
git -C qmdmm-src checkout --detach FETCH_HEAD
echo "QMdmm HEAD: $(git -C qmdmm-src log --oneline -1)"

version=$(awk '/^project\(/ { in_project = 1 } \
              in_project && /VERSION/ { \
                sub(/.*VERSION[ \t]+/, ""); sub(/[ \t].*/, ""); print; exit \
              }' qmdmm-src/CMakeLists.txt)
if [ -z "$version" ]; then
  echo "::error::no VERSION found in qmdmm-src/CMakeLists.txt"
  exit 1
fi

# QT_ROOT_DIR comes from install-qt-action's set-env, and it is asserted rather
# than assumed: a prefix that is empty would turn CMAKE_PREFIX_PATH into a
# search for Qt anywhere, and the build would then find nothing and fail
# somewhere less legible than here.
if [ -z "${QT_ROOT_DIR:-}" ]; then
  echo "::error::QT_ROOT_DIR is not set; the install-qt-action step is what provides it"
  exit 1
fi
echo "official Qt at $QT_ROOT_DIR"

# The macOS version this line's product declares, read off the Qt it links
# against rather than written down here. What actually binds a user is the floor
# of the Qt inside the bundle, so it is QtCore's own load command that gets
# asked; reading it and passing it on keeps the declared value equal to the real
# one, and lets it follow Qt's next release without anyone coming back to edit a
# number.
#
# It is not only a declaration. With a deployment target set, the compiler
# links against that version's SDK surface - new symbols become weak - so the
# bundle stops depending on whatever API the SDK of the macOS that happened to
# build it offers. Left unset, CMake takes that host SDK version instead, which
# is how this line came to declare 26.0 while the Qt it carries declares 13.0.
#
# Read from the framework's binary and not from a plist: it is the load command
# the loader acts on. Note that no earlier step should have written that number
# down either - if a floor is ever needed before Qt is installed, it is a sign
# this reading has been bypassed.
qt_core="$QT_ROOT_DIR/lib/QtCore.framework/Versions/A/QtCore"
if [ ! -f "$qt_core" ]; then
  echo "::error::no QtCore binary at $qt_core; the floor this line declares is read out of it"
  exit 1
fi
# One value per slice. A universal Qt normally gives the same one twice; taking
# the highest is what binds a user, since a machine must satisfy the strictest
# slice it may run.
qt_minos=$(vtool -show-build "$qt_core" | awk '$1 == "minos" { print $2 }' | sort -V | tail -1)
if [ -z "$qt_minos" ]; then
  echo "::error::could not read a minos out of $qt_core"
  exit 1
fi
echo "the Qt linked against here declares macOS $qt_minos; so will the bundle"

cmake -S qmdmm-src -B build -G Ninja \
  -DCMAKE_BUILD_TYPE="$QMDMM_BUILD_TYPE" \
  -DCMAKE_INSTALL_PREFIX="$PWD/inst" \
  -DCMAKE_PREFIX_PATH="$QT_ROOT_DIR" \
  -DCMAKE_IGNORE_PREFIX_PATH=/opt/homebrew \
  -DCMAKE_OSX_ARCHITECTURES="x86_64;arm64" \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$qt_minos" \
  -DBUILD_TESTING=OFF \
  -DQMDMM_EXPORT_PRIVATE=NO
cmake --build build --parallel

# Only the bundle generator: the archive generators the project also configures
# (7Z/TGZ/TXZ/TZST/ZIP) are the *other* install shape, and are what the Homebrew
# line packages. This line's product is the .dmg.
(cd build && cpack -G DragNDrop)

mkdir -p out
cp -v build/*.dmg out/
dmg=$(ls out/*.dmg | head -1)
test -n "$dmg"

# Everything below is asserted on the mounted image rather than on the build
# tree, so that what is measured is what a user gets. The mount is torn down by
# the trap whatever happens - a failed run that leaves an image attached would
# make the next step of the job fail for a reason of this one's making.
mkdir -p /tmp/mnt
hdiutil attach -nobrowse -readonly "$dmg" -mountpoint /tmp/mnt
mounted=1
cleanup() { [ "${mounted:-0}" = 1 ] && hdiutil detach /tmp/mnt >/dev/null 2>&1 || true; }
trap cleanup EXIT

app=/tmp/mnt/QMdmm6.app
test -d "$app"

failed=0

# The top level of the image, in full. Three entries is not decoration: it is
# the negative shape that stands in for this line's missing stage C. A .dmg
# carries no development content - no headers, no lib/cmake, no .pc - because
# macdeployqt copies a framework's binary and Resources and drops its Headers,
# and because there is no such thing as a "dev package" on macOS in the first
# place. Where the Linux lines prove a consumer can build against the dev
# package, this asserts that there is nothing to build against, and the
# assertion has to be exact to mean that: a fourth entry would be content
# nobody decided to ship.
top=$(ls -A /tmp/mnt)
echo "### the image's top level"
echo "$top" | sed -e 's/^/  /'
top_count=$(printf '%s\n' "$top" | grep -c .)
if [ "$top_count" -ne 3 ]; then
  echo "::error::the image has $top_count top-level entries, expected exactly 3 (Applications, QMdmm6.app, readme.md)"
  failed=1
fi
for want in QMdmm6.app Applications readme.md; do
  if ! printf '%s\n' "$top" | grep -qx "$want"; then
    echo "::error::$want is missing from the image's top level"
    failed=1
  fi
done

# The frameworks the bundle carries: 16 from Qt plus QMdmm's own two. Read as a
# number rather than a floor, because an extra one is a framework that got
# deployed by accident and a missing one is a reference that will not resolve
# when the application is started on a machine that has no Qt at all.
fw_count=$(ls -A "$app/Contents/Frameworks" | grep -c .)
echo "### Frameworks: $fw_count entries"
ls -A "$app/Contents/Frameworks" | sed -e 's/^/  /'
if [ "$fw_count" -ne 18 ]; then
  echo "::error::the bundle carries $fw_count frameworks, expected 18 (16 Qt + 2 of QMdmm's own)"
  failed=1
fi

# The platform plugins, all three of them. This is a decision with a reason
# behind it (see the QML/bundle notes in the project's own tree): macdeployqt
# deploys only libqcocoa, and the bundle's own qt.conf confines plugin lookup to
# the bundle, so a smoke test that asked for the offscreen platform used to
# abort before it started. What is required here is that offscreen is present -
# the platform stages B runs under - and the full list is printed so a
# different-but-larger set reads as information rather than as a failure.
plats=$(ls -A "$app/Contents/PlugIns/platforms")
echo "### platform plugins: $(printf '%s\n' "$plats" | grep -c .) entries"
printf '%s\n' "$plats" | sed -e 's/^/  /'
if ! printf '%s\n' "$plats" | grep -qx 'libqoffscreen.dylib'; then
  echo "::error::libqoffscreen.dylib is not in the bundle; stage B starts the GUI under the offscreen platform"
  failed=1
fi

# The ad-hoc signature macdeployqt applies at the end of the deployment. Adding
# anything to the bundle after it runs invalidates it, so this is also the
# reading that says nothing was added out of order.
if ! codesign --verify --deep --strict "$app"; then
  echo "::error::the bundle's signature does not verify"
  failed=1
fi

# The floor the bundle declares, in both of the places it is written: the main
# executable's load command, and the Info.plist key the Finder reads to decide
# whether the bundle may be opened at all. Both come from the deployment target
# read off Qt above, and asserting both is what separates "the value was carried
# through" from "one of the two is still the host SDK's version" - this is also
# the reading that would notice the deployment target quietly ceasing to apply,
# which is how a product built on macOS 26 came to declare 26.0.
app_minos=$(vtool -show-build "$app/Contents/MacOS/QMdmm6" | awk '$1 == "minos" { print $2 }' | sort -u | paste -sd, -)
info_minos=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$app/Contents/Info.plist" 2>/dev/null || true)
echo "### declared floor: load command [$app_minos] | Info.plist [$info_minos] | Qt [$qt_minos]"
if [ "$app_minos" != "$qt_minos" ]; then
  echo "::error::the bundle's executable declares macOS $app_minos, not the $qt_minos of the Qt it carries"
  failed=1
fi
if [ "$info_minos" != "$qt_minos" ]; then
  echo "::error::LSMinimumSystemVersion is '$info_minos', not the $qt_minos of the Qt the bundle carries"
  failed=1
fi

# Every Mach-O in the bundle, in both architectures. One universal product is a
# decision - it is what covers Intel machines, which have no other route left
# now that Homebrew ships no x86_64 macOS bottles - and this is the reading that
# says the decision was carried out, rather than half of it.
find "$app" -type f > /tmp/macho-candidates.txt
macho_total=0
macho_bad=''
while IFS= read -r f; do
  file -b "$f" | grep -q 'Mach-O' || continue
  macho_total=$((macho_total + 1))
  archs=$(lipo -archs "$f" 2>/dev/null || echo '?')
  if [ "$archs" != "x86_64 arm64" ]; then
    macho_bad="$macho_bad
  $f: $archs"
  fi
done < /tmp/macho-candidates.txt
echo "### Mach-O files in the bundle: $macho_total"
if [ -n "$macho_bad" ]; then
  echo "::error::these Mach-O files are not x86_64+arm64:$macho_bad"
  failed=1
fi
if [ "$macho_total" -lt 37 ]; then
  echo "::error::only $macho_total Mach-O files found; a deployed universal bundle carries 37"
  failed=1
fi

hdiutil detach /tmp/mnt >/dev/null
mounted=0

[ "$failed" -eq 0 ] || exit 1

printf 'package\tversion\tfile\n' > out/MANIFEST.tsv
printf 'qmdmm\t%s\t%s\n' "$version" "$(basename "$dmg")" >> out/MANIFEST.tsv

{
  echo '### The disk image produced'
  echo
  echo '```'
  cat out/MANIFEST.tsv
  echo '```'
  echo
  echo 'This is the self-contained install shape: one .dmg carrying a'
  echo 'QMdmm6.app with its own Qt inside it, a symlink to /Applications to'
  echo 'drag it to, and a readme. It is universal - x86_64 and arm64 in one'
  echo 'product - and the image holds no development content at all, which is'
  echo 'why this line has no stage C: there is nothing to build against.'
  echo
  echo "It declares macOS $qt_minos as its floor, in the executable's load"
  echo 'command and in the Info.plist key the Finder reads. That is the floor of'
  echo 'the Qt inside it, read off that Qt - not the version of whichever macOS'
  echo 'happened to build it.'
} >> "$GITHUB_STEP_SUMMARY"
