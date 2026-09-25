#!/usr/bin/env bash
#
# Stage C's run verification, in one file: start the *installed* Server, point
# the *rebuilt* Bot at it and require that the connection is established. That
# closes the loop stage C exists for - a source build against what the formula
# installed, talking to the installed runtime - and it is the half of the checks
# that needs port 6366, which is why it is a script of its own rather than part
# of build-verify-macos.sh.
#
# The same reading as ci/run-verify-linux.sh, in this platform's vocabulary: the
# connection is looked for in the socket tables, where the Linux lines read
# /proc/net/tcp and this one asks `lsof -t -nP -iTCP:6366 -sTCP:ESTABLISHED`,
# which answers with a pid or with nothing.
set +e
set -uo pipefail

export QT_QPA_PLATFORM=offscreen
export QT_QUICK_BACKEND=software

fatal() {
  grep -qiE 'Library not loaded|image not found|Symbol not found|Abort trap|Segmentation fault|Trace/BPT trap|Bus error' "$1"
}

failed=0
is_listening() { [ -n "$(lsof -t -nP -iTCP:6366 -sTCP:LISTEN 2>/dev/null)" ]; }
is_connected() { [ -n "$(lsof -t -nP -iTCP:6366 -sTCP:ESTABLISHED 2>/dev/null)" ]; }

installed_prefix=$(brew --prefix qmdmm)
installed_server="$installed_prefix/bin/QMdmmServer6"

# The installed server. It calls qFatal() when it cannot bind, so staying up is
# what "it runs" means - and something really listing on 6366 is the stronger
# reading now that there is somewhere to look for it.
"$installed_server" >/tmp/server.out 2>/tmp/server.err &
server_pid=$!
for _ in $(seq 1 40); do
  kill -0 "$server_pid" 2>/dev/null || break
  is_listening && break
  sleep 0.25
done
if kill -0 "$server_pid" 2>/dev/null; then
  echo "### the installed $installed_server is running"
  if ! is_listening; then
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
if [ "$bot_connected" -eq 1 ]; then
  echo "### the rebuilt Bot connected to the installed server over TCP"
else
  echo "::error::no established connection on port 6366: the rebuilt Bot never reached the server"
  echo "### Sockets referencing port 6366 after the failure:"
  lsof -nP -iTCP:6366 || echo '(none at all)'
  failed=1
fi
if fatal /tmp/bot.err; then
  echo "::error::the rebuilt Bot reported a fatal loading or crash message"
  failed=1
fi

kill "$bot_pid" "$server_pid" 2>/dev/null
wait 2>/dev/null

[ "$failed" -eq 0 ]
