#!/usr/bin/env bash
#
# Stage B's platform verification, in one file: check that every installed QMdmm
# binary and library resolves, then run the installed programs. Kept as one
# script per platform rather than per distribution, because none of it reads a
# package manager - what does differ per distribution is the timeout's exit
# status and the loader's wording, and both follow `DIST_KIND`.
#
# The two halves stay in this order and the first one is not walked past even
# though the whole file would survive it: a binary with an unresolved library
# fails the ldd pass first, and running it afterwards would only restate the
# loader's error.
set +e
set -uo pipefail

targets=$(ls /usr/bin/QMdmm6 /usr/bin/QMdmmBot6 /usr/bin/QMdmmServer6)
targets="$targets $(ls /usr/lib/*/libQMdmmCore6.so.* /usr/lib/*/libQMdmmNetworking6.so.* 2>/dev/null || true)"
targets="$targets $(ls /usr/lib/libQMdmmCore6.so.* /usr/lib/libQMdmmNetworking6.so.* 2>/dev/null || true)"
failed=0
for t in $targets; do
  echo "### ldd $t"
  ldd "$t" | tee /tmp/ldd.log
  if grep -q 'not found' /tmp/ldd.log; then
    echo "::error::$t has unresolved shared libraries"
    failed=1
  fi
done
[ "$failed" -eq 0 ] || exit 1

export QT_QPA_PLATFORM=offscreen

# What "still running when the timeout fired" looks like. busybox timeout - the
# one on Alpine - reports 143 (128 + SIGTERM) for a child it had to kill, where
# GNU coreutils reports 124. The accepted set follows each line's own timeout
# instead of taking both everywhere: on the glibc lines a 143 would mean
# something *else* killed the program, which is exactly what this check exists
# to catch.
timeout_rcs='0 124'
if [ "$DIST_KIND" = apk ]; then timeout_rcs='0 124 143'; fi
survived() {
  local r
  for r in $timeout_rcs; do
    [ "$1" = "$r" ] && return 0
  done
  return 1
}
# The loader's own words for a failure, and musl phrases it differently from
# glibc: a missing library is "version X not found" there, and a crash is
# Segmentation/Aborted rather than a shared-library error.
fatal() {
  local re='error while loading shared libraries|undefined symbol|symbol lookup error'
  if [ "$DIST_KIND" = apk ]; then
    re='error while loading|version .* not found|undefined symbol|symbol lookup error|Segmentation|Aborted'
  fi
  grep -qiE "$re" "$1"
}

# Seeing the connection the server accepted is what turns "the bot is running"
# into "the bot really reached the server". That is read out of the kernel's
# socket tables, where QMdmm's default TCP port 6366 spells 18DE and 0A/01 mean
# LISTEN/ESTABLISHED. If a container ever hides those files, warn and fall back
# to liveness: a blind harness must not fail an otherwise sound package, and the
# warning says the check was skipped.
port_hex=18DE
net_files=''
for f in /proc/net/tcp /proc/net/tcp6; do
  if [ -r "$f" ]; then net_files="$net_files $f"; fi
done
net_visible=0
[ -n "$net_files" ] && net_visible=1
# Both tables, deliberately: the server listens on QHostAddress::Any, which Qt
# maps to the dual-stack IPv6 wildcard, so its socket lives in tcp6 - and the
# address width differs between the two files, hence the unanchored [0-9A-F]+.
# $net_files is meant to word-split.
is_listening() { grep -qE ":${port_hex} +[0-9A-F]+:[0-9A-F]{4} +0A" $net_files; }
is_connected() { grep -qE ":${port_hex} +[0-9A-F]+:[0-9A-F]{4} +01" $net_files; }
if [ "$net_visible" -eq 0 ]; then
  echo "::warning::neither /proc/net/tcp nor /proc/net/tcp6 is readable here; the connection checks are skipped"
fi

{
  echo '### Programs started from the installed runtime package'
  echo
  echo 'rc 124 (GNU timeout) and rc 143 (busybox timeout) both mean the'
  echo 'program was still running when the timeout hit, which is what a'
  echo 'GUI, a server and a bot are supposed to do.'
  echo
} >> "$GITHUB_STEP_SUMMARY"

# The GUI is the only program that runs on its own.
timeout 20 /usr/bin/QMdmm6 >/tmp/gui.out 2>/tmp/gui.err
rc=$?
echo "### /usr/bin/QMdmm6 rc=$rc"
sed -e 's/^/  err| /' /tmp/gui.err
if ! survived "$rc"; then
  echo "::error::QMdmm6 exited with rc=$rc"
  failed=1
fi
if fatal /tmp/gui.err; then
  echo "::error::QMdmm6 reported a fatal loading or crash message"
  failed=1
fi
# Staying alive is not the whole story for a GUI: with the QML resource prefix
# wrong it does exactly that and still shows an empty window, complaining only
# that its own qrc path is missing. Same assertion as the rebuilt GUI in stage C
# - the packaged GUI has to resolve its QML out of its own resources, not out of
# the build tree.
if grep -q 'No such file or directory' /tmp/gui.err; then
  echo "::error::the installed GUI could not resolve its QML out of its own resources"
  failed=1
fi
# That warning is only a negative, and on Fedora gui.err is empty either way, so
# also ask the binary itself. The path below is both what
# QMdmmGui/src/mainwindow.cpp asks the resource system for and where the QTP0001
# policy puts a QML module's resources, so the two agreeing is exactly what has
# to hold. Qt keeps these strings as UTF-16 - an ASCII grep finds nothing at all
# - hence `strings -e l`, and `-a` so the whole file is read rather than the data
# sections. Deliberately not main.qml: mainwindow.cpp spells that path out in a
# literal of its own, so it is compiled in whether the prefix is right or not. A
# name only the compiled QML table carries moves with the prefix; this was
# measured against a build with the prefix forced wrong (it drops from one
# occurrence to none).
strings -a -e l /usr/bin/QMdmm6 >/tmp/gui.strings
if ! grep -q '/qt/qml/QMdmm/Gui/qml/GameScene.qml' /tmp/gui.strings; then
  echo "::error::the installed GUI does not carry its QML at qrc:/qt/qml/QMdmm/Gui/qml"
  failed=1
fi

# The server calls qFatal() when it cannot listen, which aborts with a non-zero
# status, so staying alive is what "it runs" means here.
/usr/bin/QMdmmServer6 >/tmp/server.out 2>/tmp/server.err &
server_pid=$!
for _ in $(seq 1 40); do
  kill -0 "$server_pid" 2>/dev/null || break
  if [ "$net_visible" -eq 1 ] && is_listening; then break; fi
  sleep 0.25
done
if kill -0 "$server_pid" 2>/dev/null; then
  echo "### /usr/bin/QMdmmServer6 is running"
  if [ "$net_visible" -eq 1 ] && ! is_listening; then
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

# The bot refuses to start at all without --host (it exits 3 instead of running)
# and, with one, it stays in its event loop forever: an exit status alone cannot
# tell "connected" from "dialling a host that never answers", because the client
# simply retries. The proof is the accepted connection on the server side, which
# only exists once the packaged client really got through over the packaged
# stack.
/usr/bin/QMdmmBot6 --host=qmdmm://localhost:6366 >/tmp/bot.out 2>/tmp/bot.err &
bot_pid=$!
bot_connected=0
for _ in $(seq 1 60); do
  kill -0 "$bot_pid" 2>/dev/null || break
  if is_connected; then bot_connected=1; break; fi
  sleep 0.25
done
if kill -0 "$bot_pid" 2>/dev/null; then
  echo "### /usr/bin/QMdmmBot6 is up and in its event loop"
else
  wait "$bot_pid"
  rc=$?
  echo "::error::QMdmmBot6 exited with rc=$rc instead of staying connected"
  failed=1
fi
sed -e 's/^/  err| /' /tmp/bot.err
if [ "$bot_connected" -eq 1 ]; then
  echo "### /usr/bin/QMdmmBot6 connected to /usr/bin/QMdmmServer6 over TCP"
elif [ "$net_visible" -eq 1 ]; then
  echo "::error::no established connection on port 6366: the bot never reached the server"
  # Leave evidence behind: which sockets the kernel does know about says far
  # more than "it did not work". 02 is SYN_SENT (nothing is answering), 04/06
  # mean the handshake finished and the far end then closed, 01 means it is up
  # right now.
  echo "### Sockets referencing port 6366 after the failure:"
  grep -hE ":${port_hex} " $net_files || echo '(none at all)'
  failed=1
fi
if fatal /tmp/bot.err; then
  echo "::error::QMdmmBot6 reported a fatal loading or crash message"
  failed=1
fi

# The server's own log is the other side of that connection.
server_log=$(ls -1t /var/QMdmm/log/QMdmmServer-* 2>/dev/null | head -1)
if [ -n "$server_log" ] && [ -s "$server_log" ]; then
  {
    echo "### Server-side log (\`$server_log\`)"
    echo
    echo '```'
    tail -40 "$server_log"
    echo '```'
  } >> "$GITHUB_STEP_SUMMARY"
fi

kill "$bot_pid" "$server_pid" 2>/dev/null
wait 2>/dev/null

[ "$failed" -eq 0 ]
