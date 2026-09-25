#!/usr/bin/env bash
#
# The macOS counterpart of ci/runtime-verify-linux.sh: the verification
# question, in one file, for the faces this platform has. MACOS_FACE picks the
# face; there are two of them, `brew` and `dmg`, and that switch is the whole of
# the difference between the lines.
#
# Two things follow the face, and only two:
#
#   where the programs are
#     brew   <brew --prefix qmdmm>/bin/{QMdmm6,QMdmmServer6,QMdmmBot6}
#     dmg    /Applications/QMdmm6.app/Contents/MacOS/... (stage B copies it there)
#
#   which way the dependency assertion points - the same `otool -L` reading on
#   both faces, with the opposite expectation:
#     brew   every program must resolve *into* /opt/homebrew. One that does not
#            is one that did not link against the Qt the formula declares.
#     dmg    nothing may resolve *outside* the bundle and the system. Anything
#            else means the bundle is not self-contained after all.
#
# A face that only borrows this file's structure would be a lie, so the branch
# above is explicit rather than inferred.
#
# What does NOT follow the face is the rest: the GUI has to survive, its QML has
# to resolve out of its own resources, the server has to listen and the bot has
# to be seen connecting to it. Those are the same reading on both faces and on
# the four Linux lines, which is why they are one file rather than two.
#
# Three things are macOS-specific and have no counterpart in the Linux script:
#
#   * `otool -L` is not `ldd`. It lists load commands and does not resolve them,
#     so it can never report "not found": the only thing it can prove is where
#     the references *point*. "Resolves" is then left to the programs actually
#     running, and the loader's own words for a failure are in `fatal()` below.
#   * There is no `/proc/net/tcp`; `lsof -t` answers the same question and
#     answers it with a pid or nothing, which needs no header handling.
#   * There is no `timeout`: coreutils is not part of the image. The workflow
#     installs it as a declared harness dependency - the footing the Alpine line
#     puts bash on - and the reading is `gtimeout`, which is GNU timeout and
#     reports the same 124 the Linux lines read. The `g` prefix is also what
#     keeps it from shadowing anything BSD that was already here.
#
#     An earlier version of this file argued the other way, that installing
#     coreutils would put more into /opt/homebrew than the line under test, and
#     wrote a twenty-line polling watchdog instead. That is reversed because the
#     watchdog was doing what one GNU tool does, and because what stage B asserts
#     is about the package's *own* references: no Qt appears on this runner by
#     construction - the stage checks that before it installs anything - and
#     nothing coreutils brings can stand in for the Qt that assertion is about.
set +e
set -uo pipefail

face=${MACOS_FACE:-}
case "$face" in
  brew)
    prefix=$(brew --prefix qmdmm)
    progdir="$prefix/bin"
    libdir="$prefix/lib"
    ;;
  dmg)
    # The self-contained face: the application bundle stage B copied onto this
    # machine, carrying its own Qt. `prefix` is deliberately left unset here -
    # the two places that used it address the bundle instead, and anything that
    # reached for a prefix would be addressing a filesystem layout this face
    # does not have.
    progdir=/Applications/QMdmm6.app/Contents/MacOS
    libdir=/Applications/QMdmm6.app/Contents/Frameworks
    ;;
  *)
    echo "::error::MACOS_FACE must be 'brew' or 'dmg'; got '$face'"
    exit 1
    ;;
esac

# gtimeout comes from coreutils, which the workflow installs; checked here rather
# than left to fail in the middle of a run, so a missing harness dependency reads
# as itself.
if ! command -v gtimeout >/dev/null; then
  echo "::error::gtimeout is not on this runner; the workflow installs coreutils for it"
  exit 1
fi

progs=("$progdir/QMdmm6" "$progdir/QMdmmServer6" "$progdir/QMdmmBot6")
libs=()
for f in "$libdir"/libQMdmm*.dylib; do
  [ -e "$f" ] && libs+=("$f")
done

failed=0
targets=("${progs[@]}" "${libs[@]}")
{
  echo '### Where the installed programs are'
  echo
  echo '```'
  ls -l "${progs[@]}" "${libs[@]}" 2>&1
  echo '```'
} >> "$GITHUB_STEP_SUMMARY"

# The dependency assertion. `otool -L` prints the file name on its own line and
# one tab-indented entry per load command after it.
#
# The indent is deliberately not written as `\t`: this is BSD sed, which does not
# know that escape, and a pattern that never matches would leave every assertion
# below passing vacuously. `tail -n +2` drops the header line and `[[:space:]]`
# matches the indent - measured against a real installed GUI, where it extracts
# nine /opt/homebrew references.
#
# Piping this into `grep -q` is safe where the same shape is not, and the
# difference is measured rather than assumed: the line is under the pipe buffer,
# so nothing here blocks or writes after the reader has gone. 200 runs of the
# pipeline below returned zero for every one. `qml_occurrences` further down is
# the case that is not safe, and says why.
deps() { otool -L "$1" | tail -n +2 | sed -nE 's/^[[:space:]]*(\/[^ ]*).*/\1/p'; }
for t in "${targets[@]}"; do
  echo "### otool -L $t"
  otool -L "$t" | sed -e 's/^/  /'
  if [ "$face" = brew ]; then
    # Built against Homebrew's Qt, so its libraries have to come from
    # Homebrew. A program that resolves nowhere near /opt/homebrew was built
    # against something else - a Qt from the image, a Qt left over from an
    # earlier step - and the bottle would not carry that.
    if ! deps "$t" | grep -q '^/opt/homebrew/'; then
      echo "::error::$t resolves nothing into /opt/homebrew, so it did not link against the Qt the formula declares"
      failed=1
    fi
  else
    # The self-contained face, and the same `otool -L` reading with the
    # opposite expectation: nothing may resolve *outside* the bundle and the
    # system. `deps` prints absolute paths only, so a fully deployed bundle is
    # one whose every absolute reference is /System or /usr/lib - Qt arrives
    # through @rpath into Contents/Frameworks, a relative lookup that does not
    # appear here at all. Anything else is a reference to a Qt prefix, to
    # Homebrew, or to the directory it was built in, and each of those means the
    # bundle is not self-contained after all.
    outside=$(deps "$t" | grep -vE '^/(System|usr/lib)/' | grep -c . || true)
    if [ "${outside:-0}" -ne 0 ]; then
      echo "::error::$t resolves $outside path(s) outside the bundle and the system, so it is not self-contained:"
      deps "$t" | grep -vE '^/(System|usr/lib)/' | sed -e 's/^/  /'
      failed=1
    fi
  fi
  # Neither face may point at where it was built: a bottle is relocated and an
  # application bundle is deployed, and either one leaving a build-time path
  # behind is that step having quietly not happened.
  if deps "$t" | grep -qE '^/(Users|private)/'; then
    echo "::error::$t still points into a build directory:"
    deps "$t" | grep -E '^/(Users|private)/' | sed -e 's/^/  /'
    failed=1
  fi
done
[ "$failed" -eq 0 ] || exit 1

# Both are taken from QMdmmGui/src/mainwindow.cpp's own expectations, and both
# matter for the same reason: with the QML resource prefix wrong the GUI links,
# starts and survives exactly as it does here, and shows an empty window. The
# compiled QML table is what moves with the prefix, which is why the check reads
# the binary rather than the sources.
#
# Qt stores these paths as UTF-16, so a plain grep finds nothing. The Linux lines
# read them with `strings -e l`; that spelling does not exist here, because this
# platform's strings is the LLVM one, whose only options are -a, -o, -t, -n and
# -arch - asking for -e is an error, not an empty result. What works instead uses
# the encoding itself: in UTF-16 an ASCII character is one byte followed by NUL,
# so deleting the NULs turns the stored string back into the string. Measured on
# a real binary: the target path and a positive control (qml/main.qml) hit once
# each, a negative control hits zero, and both `grep -a` on the raw file and
# `strings -a` report nothing - which is why this is measured rather than
# guessed at.
#
# The NULs are stripped into a file rather than down a pipe, which is how the
# Linux lines read their own `strings` output, and this is the reason that is not
# a stylistic choice: `grep -q` stops at its first match, so a writer still
# holding a pipe nobody reads dies of SIGPIPE - 141 - and `set -o pipefail` makes
# that the pipeline's status. Measured on a real GUI (1.1 MB): piped, a hit
# returned 141 and a miss returned 1, so the `if !` this replaced could never
# pass, and it reported a missing QML whether the QML was there or not. Read as a
# file, a hit returns 0 with a count and a miss returns 1 with a zero.
#
# The count is kept as the reading rather than reduced to a yes: a criterion that
# only ever compares against zero is what hid this one.
qml_occurrences() {
  # LC_ALL=C so tr treats the file as bytes: under a UTF-8 locale it stops at the
  # first byte sequence that is not valid UTF-8, which is most of a Mach-O.
  LC_ALL=C tr -d '\000' < "$1" > /tmp/qml-ascii.bin
  # grep -c reports 1 for a count of zero, hence the `|| true`: here the number is
  # the result and the exit status is not.
  LC_ALL=C grep -a -c -- "$2" /tmp/qml-ascii.bin || true
}
export QT_QPA_PLATFORM=offscreen
# The runner has no GPU and no session, and the four Linux lines get away with
# not setting this because their Qt does not try the accelerated backend under
# the offscreen platform. QMdmm's own CI sets it on macOS for exactly this
# reason (QMdmmGui/test/CMakeLists.txt).
export QT_QUICK_BACKEND=software

# What "still running when the timeout fired" looks like, read the way the Linux
# lines read it. gtimeout is GNU timeout, so its own number is 124; 0 is accepted
# here for the same reason it is there. Their Alpine line adds 143, which is
# busybox timeout's number and has no counterpart on this platform.
timeout_rcs='0 124'
survived() {
  local r
  for r in $timeout_rcs; do
    [ "$1" = "$r" ] && return 0
  done
  return 1
}

# The loader's and the kernel's own words for a failure. "Library not loaded"
# and "image not found" are what dyld says when a reference does not resolve -
# the thing `otool -L` above can never tell us.
fatal() {
  grep -qiE 'Library not loaded|image not found|Symbol not found|Abort trap|Segmentation fault|Trace/BPT trap|Bus error' "$1"
}

is_listening() { [ -n "$(lsof -t -nP -iTCP:6366 -sTCP:LISTEN 2>/dev/null)" ]; }
is_connected() { [ -n "$(lsof -t -nP -iTCP:6366 -sTCP:ESTABLISHED 2>/dev/null)" ]; }

{
  echo '### Programs started from the installed package'
  echo
  echo 'rc 124 (gtimeout) means the program was still running when the timeout'
  echo 'fired, which is what a GUI, a server and a bot are supposed to do.'
  echo
} >> "$GITHUB_STEP_SUMMARY"

# The GUI is the only program that runs on its own.
gtimeout 20 "${progs[0]}" >/tmp/gui.out 2>/tmp/gui.err
rc=$?
echo "### ${progs[0]} rc=$rc"
sed -e 's/^/  err| /' /tmp/gui.err
if ! survived "$rc"; then
  echo "::error::QMdmm6 exited with rc=$rc"
  failed=1
fi
if fatal /tmp/gui.err; then
  echo "::error::QMdmm6 reported a fatal loading or crash message"
  failed=1
fi
if grep -q 'No such file or directory' /tmp/gui.err; then
  echo "::error::the installed GUI could not resolve its QML out of its own resources"
  failed=1
fi
qml_hits=$(qml_occurrences "${progs[0]}" '/qt/qml/QMdmm/Gui/qml/GameScene.qml')
echo "### QML resource path occurrences in ${progs[0]}: $qml_hits"
if [ "${qml_hits:-0}" -lt 1 ]; then
  echo "::error::the installed GUI does not carry its QML at qrc:/qt/qml/QMdmm/Gui/qml"
  failed=1
fi

# The server calls qFatal() when it cannot listen, so staying up is what "it
# runs" means here - plus, now that there is somewhere to look, that something
# really is listening.
"${progs[1]}" >/tmp/server.out 2>/tmp/server.err &
server_pid=$!
for _ in $(seq 1 40); do
  kill -0 "$server_pid" 2>/dev/null || break
  is_listening && break
  sleep 0.25
done
if kill -0 "$server_pid" 2>/dev/null; then
  echo "### ${progs[1]} is running"
  if ! is_listening; then
    echo "::error::QMdmmServer6 is up but nothing is listening on TCP 6366"
    failed=1
  fi
else
  wait "$server_pid"
  rc=$?
  sed -e 's/^/  err| /' /tmp/server.err
  echo "::error::QMdmmServer6 exited with rc=$rc"
  failed=1
fi

# The bot refuses to start without --host (it exits 3) and, with one, sits in
# its event loop even when nothing answers, because the client retries. The
# accepted connection is therefore the proof, and it is read from the socket
# tables rather than from the bot's own output.
"${progs[2]}" --host=qmdmm://localhost:6366 >/tmp/bot.out 2>/tmp/bot.err &
bot_pid=$!
bot_connected=0
for _ in $(seq 1 60); do
  kill -0 "$bot_pid" 2>/dev/null || break
  if is_connected; then bot_connected=1; break; fi
  sleep 0.25
done
if kill -0 "$bot_pid" 2>/dev/null; then
  echo "### ${progs[2]} is up and in its event loop"
else
  wait "$bot_pid"
  rc=$?
  echo "::error::QMdmmBot6 exited with rc=$rc instead of staying connected"
  failed=1
fi
sed -e 's/^/  err| /' /tmp/bot.err
if [ "$bot_connected" -eq 1 ]; then
  echo "### ${progs[2]} connected to QMdmmServer6 over TCP"
else
  echo "::error::no established connection on port 6366: the bot never reached the server"
  echo "### Sockets referencing port 6366 after the failure:"
  lsof -nP -iTCP:6366 || echo '(none at all)'
  failed=1
fi
if fatal /tmp/bot.err; then
  echo "::error::QMdmmBot6 reported a fatal loading or crash message"
  failed=1
fi

# The server's own log is the other side of that connection. Where it lives
# follows the install prefix the package was built with, which is not worth
# asserting: this is evidence for the summary, not a criterion.
{
  echo '### Server-side log'
  echo
  echo '```'
  found=0
  # `${prefix:+...}` because the dmg face has no install prefix, and this
  # script runs under `set -u`. Not finding a log is not a failure: this block
  # is evidence for the summary, not a criterion.
  for candidate in "${prefix:+$prefix/var/QMdmm/log}" /usr/local/var/QMdmm/log "$HOME/Library/Application Support/QMdmm/log"; do
    [ -n "$candidate" ] || continue
    [ -d "$candidate" ] || continue
    log=$(ls -1t "$candidate"/QMdmmServer-* 2>/dev/null | head -1)
    if [ -n "$log" ] && [ -s "$log" ]; then
      echo "$log"
      tail -40 "$log"
      found=1
      break
    fi
  done
  [ "$found" -eq 1 ] || echo "(no server log found in the usual places)"
  echo '```'
} >> "$GITHUB_STEP_SUMMARY"

kill "$bot_pid" "$server_pid" 2>/dev/null
wait 2>/dev/null

[ "$failed" -eq 0 ]
