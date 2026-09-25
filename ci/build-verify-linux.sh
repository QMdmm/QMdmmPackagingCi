#!/usr/bin/env bash
#
# Stage C's build verification, in one file: build the consumer project against
# the installed dev package, then prove what it produced - the three executables
# link, the rebuilt GUI carries its QML out of its own resources, and the
# rebuilt GUI and Server run.
#
# One script for every distribution rather than one per kind, because none of
# this reads a package manager: what does differ is the generator (Alpine's
# cmake wants Unix Makefiles, since its ninja-build package puts the binary off
# PATH) and the timeout's exit status and the loader's wording, which follow
# `DIST_KIND`.
#
# The rebuilt Bot and the installed Server are the *other* script: the rebuilt
# Server runs here, while port 6366 is still free, and the installed one runs
# there.
set -euxo pipefail

# What the harness used to print from a step of its own with `if: always()`: it
# is worth most when the build in between failed, so it hangs off the script's
# exit rather than off the happy path.
write_summary() {
  {
    echo '### What the consumer project proved'
    echo
    echo '`consumer/` links nothing but the installed package:'
    echo '`find_package(QMdmm6 0.0.1 REQUIRED COMPONENTS Core Networking)`,'
    echo 'then QMdmm''s own QMdmmGui, QMdmmBot and QMdmmServer sources are'
    echo 'added with `add_subdirectory` and resolved against `QMdmm6::Core`'
    echo 'and `QMdmm6::Networking`. A green run means the dev package is'
    echo 'sufficient to rebuild all three applications. On the apk line that'
    echo 'rests on `depends_dev` in packaging/alpine/APKBUILD, since apk'
    echo 'installs nothing beyond what a package declares.'
    echo
    echo 'The rebuilt GUI is checked for a resolved QML resource, not just'
    echo 'for staying alive, and the rebuilt Bot is pointed at the installed'
    echo '`QMdmmServer6` (the dev package drags the runtime in) and has to'
    echo 'get through - so a source build against the dev package really'
    echo 'talks to the packaged runtime.'
    echo
    echo '```'
    grep -E 'QMdmm6_VERSION|QT_GENERATION|Qt6.*DIR' /tmp/consumer-configure.log \
      | head -20 || true
    echo '```'
  } >> "$GITHUB_STEP_SUMMARY"
}
trap write_summary EXIT

# Ninja everywhere except Alpine, whose cmake defaults to it while the
# ninja-build package puts the binary off PATH - that line asks for Unix
# Makefiles, which is also why its toolchain installs `make`.
generator='Ninja'
if [ "$DIST_KIND" = apk ]; then generator='Unix Makefiles'; fi
cmake -S consumer -B consumer-build -G "$generator" \
  -DCMAKE_BUILD_TYPE="$QMDMM_BUILD_TYPE" \
  -DQMDMM_SOURCE_DIR="$PWD/qmdmm-src" 2>&1 | tee /tmp/consumer-configure.log
cmake --build consumer-build --parallel

# GitHub runs the step body with -e, and every assertion below is about a
# non-zero exit status, so errexit is turned off explicitly.
set +e
set -uo pipefail
failed=0
for exe in consumer-build/qmdmm-gui/QMdmm6 \
           consumer-build/qmdmm-bot/QMdmmBot6 \
           consumer-build/qmdmm-server/QMdmmServer6; do
  if [ -x "$exe" ]; then
    echo "### built: $exe"
    ldd "$exe" | tee /tmp/ldd.log
    if grep -q 'not found' /tmp/ldd.log; then
      echo "::error::$exe has unresolved shared libraries"
      failed=1
    fi
  else
    echo "::error::$exe was not produced"
    failed=1
  fi
done

export QT_QPA_PLATFORM=offscreen

# Same two criteria as stage B, and the same reasoning: what counts as "still
# running" and what counts as a failure both follow the distribution's own
# timeout and loader.
timeout_rcs='0 124'
if [ "$DIST_KIND" = apk ]; then timeout_rcs='0 124 143'; fi
survived() {
  local r
  for r in $timeout_rcs; do
    [ "$1" = "$r" ] && return 0
  done
  return 1
}
fatal() {
  local re='error while loading shared libraries|undefined symbol|symbol lookup error'
  if [ "$DIST_KIND" = apk ]; then
    re='error while loading|version .* not found|undefined symbol|symbol lookup error|Segmentation|Aborted'
  fi
  grep -qiE "$re" "$1"
}

timeout 20 consumer-build/qmdmm-gui/QMdmm6 >/tmp/gui.out 2>/tmp/gui.err
rc=$?
echo "### rebuilt GUI rc=$rc"
sed -e 's/^/  err| /' /tmp/gui.err
if ! survived "$rc"; then
  echo "::error::rebuilt GUI exited with rc=$rc"
  failed=1
fi
if fatal /tmp/gui.err; then
  echo "::error::the rebuilt GUI reported a fatal loading or crash message"
  failed=1
fi
# Linking and staying alive is not the whole story for this one: with the QML
# resource prefix wrong it does both of those and still shows an empty window,
# complaining only that its own qrc path is missing.
if grep -q 'No such file or directory' /tmp/gui.err; then
  echo "::error::the rebuilt GUI could not resolve its QML out of its own resources"
  failed=1
fi
# Same static check as stage B, with the same reasoning. It matters more here:
# what decides the prefix for this build is the consumer's own
# qt6_standard_project_setup, and leaving that out is a mistake this harness has
# made once already - the GUI then links, starts, and shows an empty window.
strings -a -e l consumer-build/qmdmm-gui/QMdmm6 >/tmp/rgui.strings
if ! grep -q '/qt/qml/QMdmm/Gui/qml/GameScene.qml' /tmp/rgui.strings; then
  echo "::error::the rebuilt GUI does not carry its QML at qrc:/qt/qml/QMdmm/Gui/qml"
  failed=1
fi

# The rebuilt server on its own first, while 6366 is still free; the installed
# one, in the next script, needs that port.
timeout 10 consumer-build/qmdmm-server/QMdmmServer6 >/tmp/rserver.out 2>/tmp/rserver.err
rc=$?
echo "### rebuilt Server rc=$rc"
sed -e 's/^/  err| /' /tmp/rserver.err
if ! survived "$rc"; then
  echo "::error::rebuilt Server exited with rc=$rc"
  failed=1
fi
if fatal /tmp/rserver.err; then
  echo "::error::the rebuilt Server reported a fatal loading or crash message"
  failed=1
fi

[ "$failed" -eq 0 ]
