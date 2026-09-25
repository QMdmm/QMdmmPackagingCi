#!/usr/bin/env bash
#
# Stage B for the Homebrew line, in one file: assert the runner really has no
# Qt, tap the repository, take stage A's formula (the one carrying the bottle
# block), serve that bottle over loopback, pour it, and insist that it was
# poured rather than built.
#
# See runtime-deb.sh for why stage B starts clean and installs by name. On macOS
# there is no container to be clean in, so a fresh runner takes its place - with
# one difference worth keeping in view: a container starts out empty, while a
# macOS runner image already carries Homebrew, cmake and ninja in /opt/homebrew.
# Qt is the one package that would make this stage vacuous and it is *not* in the
# image (the toolset's `brew.common_packages` has no qt), which is why "no Qt
# before the install" is asserted below rather than believed.
set -euxo pipefail

# "Clean" as a reading. If a Qt were already here, the pour below would satisfy
# the formula's dependency whatever the formula declared, and the half of this
# stage that asks "are the declared dependencies complete" would be answering
# nothing.
if ls /opt/homebrew/opt 2>/dev/null | grep -qx qt; then
  echo "::error::Qt is already installed on this runner, so a missing dependency could not be told from a satisfied one"
  ls -l /opt/homebrew/opt/qt
  exit 1
fi
for tool in qmake6 qtpaths6 moc; do
  if command -v "$tool" >/dev/null; then
    echo "::error::$tool is on PATH before anything was installed"
    exit 1
  fi
done
echo "no Qt on this runner yet, which is what stage B starts from"

brew tap "$HOMEBREW_TAP"
brew trust --tap "$HOMEBREW_TAP"
tap_dir=$(brew --repo "$HOMEBREW_TAP")

# Stage A's formula rather than the repository's: it is the one carrying the
# bottle block with this run's checksum, and the block's root_url is the loopback
# address served two steps below.
test -f pkgs/qmdmm.rb
install -m 644 pkgs/qmdmm.rb "$tap_dir/Formula/qmdmm.rb"
grep -A6 '^  bottle do' "$tap_dir/Formula/qmdmm.rb"

# The root_url is a convention between the stages and nothing more: stage A
# cannot reach the machine that will pour the bottle, and a published URL is not
# this workflow's to use. So every consuming stage serves its own copy of the
# bottle directory at the address the formula names - which keeps the pour below
# a real download with a real checksum check, exactly as a user's would be.
mkdir -p serve
cp pkgs/bottles/*.bottle.tar.gz serve/
serve_dir=$PWD/serve
bottle_file=$(basename "$(ls pkgs/bottles/*.bottle.tar.gz | head -1)")

case "$BOTTLE_ROOT_URL" in
  http://127.0.0.1:* | http://localhost:*) ;;
  *)
    echo "::error::BOTTLE_ROOT_URL ($BOTTLE_ROOT_URL) is not a loopback address, and this stage must not depend on anything outside the job"
    exit 1
    ;;
esac
port=${BOTTLE_ROOT_URL##*:}
if command -v python3 >/dev/null; then
  python3 -m http.server "$port" --directory "$serve_dir" >/tmp/httpd.log 2>&1 &
else
  # macOS still ships a ruby, and webrick comes with it.
  ruby -run -e httpd "$serve_dir" -p "$port" >/tmp/httpd.log 2>&1 &
fi
httpd_pid=$!
trap 'kill "$httpd_pid" 2>/dev/null || true' EXIT

# Wait for the socket to answer rather than sleeping and hoping: a pour against
# a server that is not listening yet fails in a way that reads as "there is no
# bottle for this tag".
for _ in $(seq 1 40); do
  curl -fsS -o /dev/null "$BOTTLE_ROOT_URL/$bottle_file" && break
  sleep 0.25
done
if ! curl -fsS -o /dev/null "$BOTTLE_ROOT_URL/$bottle_file"; then
  echo "::error::the bottle is not being served at $BOTTLE_ROOT_URL/$bottle_file"
  sed -e 's/^/  httpd| /' /tmp/httpd.log
  exit 1
fi
echo "serving $bottle_file at $BOTTLE_ROOT_URL"

# The install, and the one thing about it that must not be left to chance. A
# formula whose bottle block disagrees with the bottle that was produced - a
# stale checksum, the file named in the two-hyphen spelling, a tag for a
# different macOS - quietly falls back to building from source. The stage would
# pass and would have verified nothing about the bottle at all, which is the
# failure mode this whole line exists to catch.
pour_log=/tmp/pour.log
brew install "$HOMEBREW_TAP/qmdmm" 2>&1 | tee "$pour_log"
if grep -qE 'Building qmdmm from source' "$pour_log"; then
  echo "::error::the install built qmdmm from source instead of pouring the bottle"
  exit 1
fi
if ! grep -qE 'Pouring qmdmm-' "$pour_log"; then
  echo "::error::no pour of qmdmm appears in the install log, so the bottle was not what got installed"
  exit 1
fi
echo "poured from the bottle, not built from source"

# The other half of "the declared dependencies are complete", stated as a
# reading: the formula declares one runtime dependency, and pouring it has to be
# what put Qt on this machine.
if ! brew list --versions qt >/dev/null 2>&1; then
  echo "::error::Qt is not installed after installing qmdmm, so depends_on \"qt\" did not do what it says"
  exit 1
fi

{
  echo '### The pour'
  echo
  echo '```'
  grep -E 'Pouring qmdmm-|==> (Downloading|Installing|Fetching)' "$pour_log" || true
  echo '```'
  echo
  echo '### What installing only qmdmm brought in'
  echo
  echo '```'
  brew list --versions qt
  brew deps --installed --include-build "$HOMEBREW_TAP/qmdmm" || true
  echo '```'
} >> "$GITHUB_STEP_SUMMARY"
