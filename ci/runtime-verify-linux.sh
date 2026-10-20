#!/usr/bin/env bash
#
# Stage B's platform verification, in one file: check that every installed QMdmm
# binary and library resolves, run the installed programs, and then let the bots
# play a game against the server to its end. Kept as one script per platform
# rather than per distribution, because none of it reads a package manager - what
# does differ per distribution is the timeout's exit status and the loader's
# wording, and both follow `DIST_KIND`.
#
# The halves stay in this order and an earlier one is not walked past even though
# the whole file would survive it: a binary with an unresolved library fails the
# ldd pass first, and running it afterwards would only restate the loader's
# error. The game comes last because it needs the server and the bots to be up,
# and because it is the only part that says the package is *playable* rather than
# merely loadable.
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

# Where the readings below come from, and the size of a room. The room size is
# handed to the server rather than read back out of it: `-d` prints only what
# differs from the defaults, so an unset key leaves nothing to read, and the bot
# count and the room's own size have to be the same number or no game is ever
# dealt. 3 is the shipped default.
control_port=6368
room_size=3

# One connection per reading: the plane answers a single request and closes, so
# there is no keep-alive to negotiate. bash's /dev/tcp is the client because none
# of the four lines is guaranteed to carry curl - a probe should not need a
# package installed for it - and `$BASH` rather than a bare `bash` because on
# Alpine /bin/sh is ash. Of the answer, the headers end with a blank line and the
# body carries no trailing newline, so the last line is the snapshot.
read_status() {
  timeout 5 "$BASH" -c "exec 3<>/dev/tcp/127.0.0.1/${control_port}; printf 'GET /status HTTP/1.0\r\n\r\n' >&3; cat <&3" 2>/dev/null | tr -d '\r' | tail -1
}

# Every key of the snapshot is a count or a list of rooms, so a count is the
# first `"key":<digits>` in it. `rounds` repeats once per room, which is why the
# busiest room's is read as the largest rather than the first.
count_of() {
  printf '%s' "$1" | grep -oE "\"$2\":[0-9]+" | grep -oE '[0-9]+$' | head -1
}
rounds_peak() {
  printf '%s' "$1" | grep -oE '"rounds":[0-9]+' | grep -oE '[0-9]+$' | sort -n | tail -1
}

# The server calls qFatal() when it cannot listen, which aborts with a non-zero
# status, so staying alive is what "it runs" means here.
/usr/bin/QMdmmServer6 -n "$room_size" --control-port "$control_port" \
  >/tmp/server.out 2>/tmp/server.err &
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
bot_pids="$bot_pid"
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

# ---------------------------------------------------------------------------
# And the room has to be playable, not only reachable.
#
# A connection says the packaged client got through; this says the package can
# play. Two readings carry it and both are stable states rather than windows to
# catch, because a three-bot game is dealt in a fraction of a second and a poller
# cannot be relied on to see "a game is running".
#
#   the seats   a second bot fills all but one of them: one room, `players` at
#               room_size - 1, and no game - a room only deals once it is full,
#               so this reading holds for as long as it takes to look at it.
#   the end     the room is gone again: `rooms` and `players` both 0 while every
#               bot is still alive. A room is destroyed when its game is over and
#               in no other way - a player that drops keeps its seat - so an
#               empty server on living bots is the end of a game that really ran.
#
# The peak round count goes into the summary as evidence and is deliberately not
# asserted: it is the one reading that moves while the game is being played, so
# it is the one a slow probe can miss.
#
# Only while everything above held - otherwise the waits below can only time out.
if [ "$failed" -eq 0 ]; then
  /usr/bin/QMdmmBot6 --host=qmdmm://localhost:6366 >/tmp/bot2.out 2>/tmp/bot2.err &
  bot2_pid=$!
  bot_pids="$bot_pids $bot2_pid"
  waiting_for=$((room_size - 1))
  seats_ok=0
  status=''
  for _ in $(seq 1 100); do
    kill -0 "$bot2_pid" 2>/dev/null || break
    status=$(read_status)
    if [ "$(count_of "$status" rooms)" = 1 ] && [ "$(count_of "$status" players)" = "$waiting_for" ]; then
      seats_ok=1
      break
    fi
    sleep 0.1
  done
  if [ "$seats_ok" -eq 1 ]; then
    echo "### a room holds $waiting_for of $room_size seats and has dealt nothing yet"
    echo "### $status"
  else
    echo "::error::the room never held $waiting_for seated bots; the game cannot start without them"
    echo "### last snapshot: ${status:-none, the control plane did not answer}"
    failed=1
  fi
fi

if [ "$failed" -eq 0 ]; then
  /usr/bin/QMdmmBot6 --host=qmdmm://localhost:6366 >/tmp/bot3.out 2>/tmp/bot3.err &
  bot3_pid=$!
  bot_pids="$bot_pids $bot3_pid"
  played=0
  peak_rounds=0
  full_room_seen=0
  status=''
  for _ in $(seq 1 200); do
    kill -0 "$bot3_pid" 2>/dev/null || break
    status=$(read_status)
    dealt=$(rounds_peak "$status")
    if [ -n "$dealt" ] && [ "$dealt" -gt "$peak_rounds" ]; then peak_rounds=$dealt; fi
    if [ "$(count_of "$status" games)" = 1 ]; then full_room_seen=1; fi
    if [ "$(count_of "$status" rooms)" = 0 ] && [ "$(count_of "$status" players)" = 0 ]; then
      played=1
      break
    fi
    sleep 0.05
  done
  if ! kill -0 "$bot3_pid" 2>/dev/null; then
    wait "$bot3_pid"
    rc=$?
    sed -e 's/^/  err| /' /tmp/bot3.err
    echo "::error::the third QMdmmBot6 exited with rc=$rc while the room was filling"
    failed=1
  elif [ "$played" -eq 1 ]; then
    echo "### the room played its game to the end, then went away"
    echo "### full room seen: $full_room_seen, peak round count: $peak_rounds"
  else
    echo "::error::the room never reached the end of a game"
    echo "### last snapshot: ${status:-none, the control plane did not answer}"
    failed=1
  fi
  for pid in $bot_pids; do
    if ! kill -0 "$pid" 2>/dev/null; then
      echo "::error::a bot exited while the game was played, so the empty server was not the end of one"
      failed=1
    fi
  done
fi

for extra in /tmp/bot2.err /tmp/bot3.err; do
  if [ -f "$extra" ] && fatal "$extra"; then
    sed -e 's/^/  err| /' "$extra"
    echo "::error::$extra reported a fatal loading or crash message"
    failed=1
  fi
done

# ---------------------------------------------------------------------------
# The negative control.
#
# A single bot fills no room, so the end-of-game reading must not arrive here.
# Without this, "the room is gone" would also be satisfied by a server that never
# accepted anybody, and the criterion above would have been part of every green
# run without ever having been shown to tell the two apart. The window is far
# longer than the game above needed, and what it waits for is structural: one bot
# short of a full room means no game is dealt at all.
if [ "$failed" -eq 0 ]; then
  for pid in $bot_pids; do
    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
  done
  sleep 0.5
  /usr/bin/QMdmmBot6 --host=qmdmm://localhost:6366 >/tmp/bot-alone.out 2>/tmp/bot-alone.err &
  alone_pid=$!
  seated=0
  status=''
  for _ in $(seq 1 100); do
    kill -0 "$alone_pid" 2>/dev/null || break
    status=$(read_status)
    if [ "$(count_of "$status" rooms)" = 1 ] && [ "$(count_of "$status" players)" = 1 ]; then
      seated=1
      break
    fi
    sleep 0.1
  done
  if [ "$seated" -ne 1 ]; then
    echo "::error::one bot on its own never took a seat; the reading above cannot be read as a game"
    echo "### last snapshot: ${status:-none, the control plane did not answer}"
    failed=1
  else
    ended_alone=0
    for _ in $(seq 1 60); do
      status=$(read_status)
      if [ "$(count_of "$status" rooms)" = 0 ] && [ "$(count_of "$status" players)" = 0 ]; then
        ended_alone=1
        break
      fi
      sleep 0.1
    done
    if [ "$ended_alone" -eq 1 ]; then
      echo "::error::a single bot reached the end-of-game reading, so that reading proves nothing"
      failed=1
    else
      echo "### one bot on its own sits in a room that never fills, which is what the reading above is not"
    fi
  fi
  kill "$alone_pid" 2>/dev/null
  wait "$alone_pid" 2>/dev/null
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

for pid in $bot_pids; do
  kill "$pid" 2>/dev/null
done
kill "$server_pid" 2>/dev/null
wait 2>/dev/null

[ "$failed" -eq 0 ]
