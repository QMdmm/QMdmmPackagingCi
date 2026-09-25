#!/usr/bin/env bash
#
# Stage C's build verification, in one file: build the consumer project against
# what the formula installed, then prove what it produced - the three
# executables link, the rebuilt GUI carries its QML out of its own resources,
# and the rebuilt GUI and Server start.
#
# One script for every face on this platform, like runtime-verify-macos.sh, and
# the rebuilt Bot against the installed Server is the other script: the rebuilt
# Server runs here, while port 6366 is free, and the installed one there.
set -euxo pipefail

# coreutils, for gtimeout, is a declared harness dependency the workflow installs
# - the footing the Alpine line puts bash on. Checked here rather than left to
# fail in the middle of a build, so it reads as itself.
if ! command -v gtimeout >/dev/null; then
  echo "::error::gtimeout is not on this runner; the workflow installs coreutils for it"
  exit 1
fi

# The prefixes, named explicitly, and that is the line this stage diverges on.
#
# `find_package(QMdmm6)` and `find_package(Qt6)` both have to be answered, and an
# install prefix is not where either is found by default: Homebrew links a keg's
# bin/ and lib/ into /opt/homebrew but leaves lib/cmake inside the keg, so a
# CMake package does not show up on its own. On the four Linux lines the dev
# package puts its CMake package where CMake looks, and no such line is needed.
#
# The list is derived rather than written out: every dependency the formula
# pulled in contributes its prefix, which is what puts qtbase, qtdeclarative,
# qtwebsockets and qtsvg - the Qt sub-modules the formula names, plus the one
# qtdeclarative brings with it - on the path without naming any of them here.
prefix_path=$(brew --prefix qmdmm)
for dep in $(brew deps --installed "$HOMEBREW_TAP/qmdmm"); do
  prefix_path="$prefix_path;$(brew --prefix "$dep")"
done
echo "CMAKE_PREFIX_PATH=$prefix_path"

# What the harness used to print from a step of its own under `if: always()`: it
# is worth most when the build in between failed, so it hangs off the script's
# exit rather than off the happy path.
write_summary() {
  {
    echo '### What the consumer project proved'
    echo
    echo '`consumer/` links nothing but the installed formula:'
    echo '`find_package(QMdmm6 0.0.1 REQUIRED COMPONENTS Core Networking)`,'
    echo 'then QMdmm''s own QMdmmGui, QMdmmBot and QMdmmServer sources are added'
    echo 'with `add_subdirectory` and resolved against `QMdmm6::Core` and'
    echo '`QMdmm6::Networking`. A green run means the one package Homebrew'
    echo 'installs - which carries the runtime, the headers and the CMake'
    echo 'package together, as Arch''s does - is sufficient to rebuild all three'
    echo 'applications.'
    echo
    echo 'The Qt CMake packages it resolved against:'
    echo
    echo '```'
    grep -E 'QMdmm6_VERSION|QT_GENERATION|Qt6.*DIR' /tmp/consumer-configure.log \
      | head -20 || true
    echo '```'
  } >> "$GITHUB_STEP_SUMMARY"
}
trap write_summary EXIT

cmake -S consumer -B consumer-build -G Ninja \
  -DCMAKE_BUILD_TYPE="$QMDMM_BUILD_TYPE" \
  -DCMAKE_PREFIX_PATH="$prefix_path" \
  -DQMDMM_SOURCE_DIR="$PWD/qmdmm-src" 2>&1 | tee /tmp/consumer-configure.log
cmake --build consumer-build --parallel

# GitHub runs the step body with -e, and every assertion below is about a
# non-zero exit status, so errexit is turned off explicitly.
set +e
set -uo pipefail
failed=0

# The same reading runtime-verify-macos.sh takes of the installed programs, for
# the same reason: built against Homebrew's Qt means the references have to
# point into Homebrew. The check that no reference points into a build directory
# is deliberately NOT made here - the rebuilt programs live in a build tree and
# their own libraries are right there next to them.
#
# `[[:space:]]+` rather than `\t`: BSD sed does not know that escape, and a
# pattern that never matches would make the assertion below pass vacuously. The
# `+` is load-bearing, for the reason runtime-verify-macos.sh measures: the file
# name is printed at column 0 and load commands are tab-indented, and a universal
# binary prints one such header per architecture, so a zero-width indent would
# read the second header as a reference to the file itself. The reading is taken
# the same way in both scripts on purpose, and so is the shape that follows it:
# piping this into `grep -q` is safe because the line is far under the pipe
# buffer, which runtime-verify-macos.sh measures and qml_occurrences there does
# not get to assume.
deps() { otool -L "$1" | sed -nE 's/^[[:space:]]+(\/[^ ]*).*/\1/p'; }
for exe in consumer-build/qmdmm-gui/QMdmm6 \
           consumer-build/qmdmm-bot/QMdmmBot6 \
           consumer-build/qmdmm-server/QMdmmServer6; do
  if [ -x "$exe" ]; then
    echo "### built: $exe"
    otool -L "$exe" | sed -e 's/^/  /'
    if ! deps "$exe" | grep -q '^/opt/homebrew/'; then
      echo "::error::$exe resolves nothing into /opt/homebrew, so it did not link against the Qt the formula declares"
      failed=1
    fi
  else
    echo "::error::$exe was not produced"
    failed=1
  fi
done

# Qt stores the QML paths as UTF-16, so a plain grep finds nothing, and this
# platform's strings is the LLVM one - it has no -e, which is what the Linux
# lines use for this. Deleting the NULs turns the stored string back into the
# string (in UTF-16 an ASCII character is one byte followed by NUL), and
# runtime-verify-macos.sh reads it the same way; the controls that were run
# against this are recorded there. LC_ALL=C because tr stops at the first byte
# sequence that is not valid UTF-8 under a UTF-8 locale, which is most of a
# Mach-O.
qml_occurrences() {
  # The file, not a pipe, and the count rather than a yes: runtime-verify-macos.sh
  # is where both were measured - a pipe into `grep -q` returned 141 on a hit, so
  # the `if !` this replaced could never pass.
  LC_ALL=C tr -d '\000' < "$1" > /tmp/qml-ascii.bin
  LC_ALL=C grep -a -c -- "$2" /tmp/qml-ascii.bin || true
}

export QT_QPA_PLATFORM=offscreen
export QT_QUICK_BACKEND=software

# The same two criteria as stage B and the Linux lines, read the same way:
# gtimeout is GNU timeout, so what counts as "still running" is its 124, and 0 is
# accepted here for the same reason it is there.
timeout_rcs='0 124'
survived() {
  local r
  for r in $timeout_rcs; do
    [ "$1" = "$r" ] && return 0
  done
  return 1
}

fatal() {
  grep -qiE 'Library not loaded|image not found|Symbol not found|Abort trap|Segmentation fault|Trace/BPT trap|Bus error' "$1"
}

gtimeout 20 consumer-build/qmdmm-gui/QMdmm6 >/tmp/gui.out 2>/tmp/gui.err
rc=$?
echo "### rebuilt GUI rc=$rc"
sed -e 's/^/  err| /' /tmp/gui.err
if ! survived "$rc"; then
  echo "::error::the rebuilt GUI exited with rc=$rc"
  failed=1
fi
if fatal /tmp/gui.err; then
  echo "::error::the rebuilt GUI reported a fatal loading or crash message"
  failed=1
fi
# Linking and staying alive is not the whole story for this one: with the QML
# resource prefix wrong it does both, and shows an empty window. It matters more
# here than in stage B, because what decides the prefix for this build is the
# consumer's own qt6_standard_project_setup, and leaving that out is a mistake
# this harness has made once already.
if grep -q 'No such file or directory' /tmp/gui.err; then
  echo "::error::the rebuilt GUI could not resolve its QML out of its own resources"
  failed=1
fi
qml_hits=$(qml_occurrences consumer-build/qmdmm-gui/QMdmm6 '/qt/qml/QMdmm/Gui/qml/GameScene.qml')
echo "### QML resource path occurrences in the rebuilt GUI: $qml_hits"
if [ "${qml_hits:-0}" -lt 1 ]; then
  echo "::error::the rebuilt GUI does not carry its QML at qrc:/qt/qml/QMdmm/Gui/qml"
  failed=1
fi

# The rebuilt server on its own first, while 6366 is still free; the installed
# one, in the next script, needs that port.
gtimeout 10 consumer-build/qmdmm-server/QMdmmServer6 >/tmp/rserver.out 2>/tmp/rserver.err
rc=$?
echo "### rebuilt Server rc=$rc"
sed -e 's/^/  err| /' /tmp/rserver.err
if ! survived "$rc"; then
  echo "::error::the rebuilt Server exited with rc=$rc"
  failed=1
fi
if fatal /tmp/rserver.err; then
  echo "::error::the rebuilt Server reported a fatal loading or crash message"
  failed=1
fi

[ "$failed" -eq 0 ]
