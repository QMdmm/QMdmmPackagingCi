#!/usr/bin/env bash
#
# Stage C's run verification, in one file: start the *installed* Server, point
# the *rebuilt* Bot at it and require that the connection is established. That
# closes the loop stage C exists for - a source build against the dev package
# talking to the packaged runtime - and it is the half of the checks that needs
# port 6366, which is why it is a script of its own rather than part of
# build-verify.sh.
#
# One script for every distribution, like build-verify.sh: what differs per kind
# is the loader's wording, and that follows `DIST_KIND`.
set +e
set -uo pipefail

export QT_QPA_PLATFORM=offscreen

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

failed=0

# Same connection probe as the runtime stage: 6366 reads 18DE in the kernel
# socket tables, 0A is LISTEN and 01 is ESTABLISHED. Falls back to liveness, with
# a warning, if those files are not readable here.
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

# The installed server, on the port the rebuilt one has given up by now.
/usr/bin/QMdmmServer6 >/tmp/server.out 2>/tmp/server.err &
server_pid=$!
for _ in $(seq 1 40); do
  kill -0 "$server_pid" 2>/dev/null || break
  if [ "$net_visible" -eq 1 ] && is_listening; then break; fi
  sleep 0.25
done
if kill -0 "$server_pid" 2>/dev/null; then
  echo "### the installed /usr/bin/QMdmmServer6 is running"
  if [ "$net_visible" -eq 1 ] && ! is_listening; then
    echo "::error::the installed QMdmmServer6 is up but nothing is listening on TCP 6366"
    failed=1
  fi
else
  wait "$server_pid"
  rc=$?
  sed -e 's/^/  err| /' /tmp/server.err
  echo "::error::the installed QMdmmServer6 exited with rc=$rc"
  failed=1
fi

# Without --host the bot exits 3; with one it stays in its event loop even when
# nothing answers, so the accepted connection - not the exit status - is what
# proves it really got through.
consumer-build/qmdmm-bot/QMdmmBot6 --host=qmdmm://localhost:6366 \
  >/tmp/bot.out 2>/tmp/bot.err &
bot_pid=$!
bot_connected=0
for _ in $(seq 1 60); do
  kill -0 "$bot_pid" 2>/dev/null || break
  if is_connected; then bot_connected=1; break; fi
  sleep 0.25
done
if kill -0 "$bot_pid" 2>/dev/null; then
  echo "### the rebuilt Bot is up and in its event loop"
else
  wait "$bot_pid"
  rc=$?
  echo "::error::the rebuilt Bot exited with rc=$rc instead of staying connected"
  failed=1
fi
sed -e 's/^/  err| /' /tmp/bot.err
if fatal /tmp/bot.err; then
  echo "::error::the rebuilt Bot reported a fatal loading or crash message"
  failed=1
fi
if [ "$bot_connected" -eq 1 ]; then
  echo "### the rebuilt Bot connected to the installed server over TCP"
elif [ "$net_visible" -eq 1 ]; then
  echo "::error::no established connection on port 6366: the rebuilt Bot never reached the server"
  echo "### Sockets referencing port 6366 after the failure:"
  grep -hE ":${port_hex} " $net_files || echo '(none at all)'
  failed=1
fi

kill "$bot_pid" "$server_pid" 2>/dev/null
wait 2>/dev/null

[ "$failed" -eq 0 ]
