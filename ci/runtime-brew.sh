#!/usr/bin/env bash
#
# Stage B for the Homebrew line, in one file: assert the runner really has no
# Qt, tap the repository, take stage A's formula (the one carrying the bottle
# block), serve that bottle over loopback, pour it, insist that it was poured
# rather than built, and run the recipe's own test block.
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
#
# Every name the formula depends on is asked about, not just `qt`: the formula
# names three sub-modules, so a runner carrying qtbase would satisfy the pour
# with the meta formula never involved - and a check keyed on `qt` alone would
# have called that runner clean.
for module in qt qtbase qtdeclarative qtwebsockets; do
  if ls /opt/homebrew/opt 2>/dev/null | grep -qx "$module"; then
    echo "::error::Qt ($module) is already installed on this runner, so a missing dependency could not be told from a satisfied one"
    ls -l "/opt/homebrew/opt/$module"
    exit 1
  fi
done
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

# This run's formula rather than the tap's own: it is the one carrying the block
# naming this run's bottles, and the block's root_url is the loopback address
# served two steps below. Which stage wrote it depends on the line - stage A's is
# the whole block on the daily line's single row, while the release line's three
# rows have their blocks assembled into one by ci/merge-brew.sh - and this stage
# does not care which, only that the block names the bottle it is about to pour.
test -f pkgs/qmdmm.rb
install -m 644 pkgs/qmdmm.rb "$tap_dir/Formula/qmdmm.rb"
grep -A6 '^  bottle do' "$tap_dir/Formula/qmdmm.rb"

# The row's own tag, declared by the workflow's matrix and checkable here. The
# tag is the compatibility floor, so a row that landed on a macOS other than the
# one it claims would be handed a neighbouring row's bottle - and would pour it,
# and pass, and verify a build nobody on the row's own macOS can install. The
# two readings below are what make the row's identity a fact: the block has to
# carry this tag, and the pour has to have fetched *this* tag's file.
: "${MACOS_TAG:?this row must declare the bottle tag of its runner, e.g. arm64_sequoia}"
if ! grep -qE "^[[:space:]]*sha256[[:space:]]+cellar: [^,]*, $MACOS_TAG:" "$tap_dir/Formula/qmdmm.rb"; then
  echo "::error::the block has no line for $MACOS_TAG, which is the tag this row declares. This runner is macOS $(sw_vers -productVersion) $(uname -m), and a block that names no tag for it pours nothing here - the install would build from source, and the assertion below would report that as a missing bottle rather than as the row's mistake. The block as it stands:"
  sed -n '/^  bottle do/,/^  end/p' "$tap_dir/Formula/qmdmm.rb"
  exit 1
fi

# The root_url is a convention between the stages and nothing more: stage A
# cannot reach the machine that will pour the bottle, and a published URL is not
# this workflow's to use. So every consuming stage serves its own copy of the
# bottle directory at the address the formula names - which keeps the pour below
# a real download with a real checksum check, exactly as a user's would be.
mkdir -p serve
cp pkgs/bottles/*.bottle.tar.gz serve/
serve_dir=$PWD/serve
# This row's own bottle, read out of the manifest rather than taken as the first
# file in the directory. Three bottles are served here now, and `head -1` would
# probe and then assert about whichever one sorted first - so a row that fetched
# the wrong macOS's bottle would be green twice over.
bottle_file=$(awk -F'\t' -v t="$MACOS_TAG" 'NR > 1 && $1 == "qmdmm" && $3 == t { print $4; exit }' pkgs/MANIFEST.tsv)
if [ -z "$bottle_file" ]; then
  echo "::error::$MACOS_TAG has no row in pkgs/MANIFEST.tsv, so this row cannot say which bottle it is here to pour:"
  cat pkgs/MANIFEST.tsv
  exit 1
fi
if [ ! -f "serve/$bottle_file" ]; then
  echo "::error::serve/$bottle_file is missing, and the manifest names it for $MACOS_TAG. serve/ holds:"; ls -l serve
  exit 1
fi
echo "this row pours $bottle_file"

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
# ... and the file it poured is the one this row exists to verify. A pour of
# another row's bottle is the failure this stage would otherwise report as a
# success: the bottle being poured is the right *formula*, and only the name says
# which macOS it was built on.
if ! grep -qF "Pouring $bottle_file" "$pour_log"; then
  echo "::error::$bottle_file was not the file poured, so this row verified another macOS's bottle. This row is $MACOS_TAG. What was poured:"
  grep -E 'Pouring ' "$pour_log" || true
  exit 1
fi
echo "poured from the bottle, not built from source, and it was this row's: $bottle_file"

# The other half of "the declared dependencies are complete", stated as a
# reading: the formula declares three Qt sub-modules, and pouring it has to be
# what put them on this machine.
for module in qtbase qtdeclarative qtwebsockets; do
  if ! brew list --versions "$module" >/dev/null 2>&1; then
    echo "::error::$module is not installed after installing qmdmm, so the formula's depends_on did not put it there"
    exit 1
  fi
done
# And the meta formula must *not* be here. Depending on `qt` installs all 39 Qt
# sub-modules, which is what this formula was changed to stop doing, and an
# assertion that only counted the three would be green either way.
if brew list --versions qt >/dev/null 2>&1; then
  echo "::error::the qt meta formula came in too, so installing qmdmm still drags in every Qt sub-module"
  exit 1
fi
echo "the three Qt sub-modules are here and the meta formula is not"

# The recipe's own test. Nothing else in this harness runs it: `brew install`
# does not call a formula's `test do` block, and none of the stages did either,
# so the block was a claim nobody checked - it names one program and one option,
# and either could stop existing with every job still green. The two stages do
# run the installed programs, and more thoroughly, but that is their reading of
# the package rather than the recipe's own; this is the one that says a user's
# `brew test qmdmm` works.
#
# It runs against stage A's copy of the formula - the tap's own file with this
# run's pin and bottle block written into it - so what is exercised is the block
# a user gets rather than a second copy of it.
cp "$tap_dir/Formula/qmdmm.rb" /tmp/qmdmm.rb.poured
test_log=/tmp/brew-test.log
# The first developer command in this stage. Homebrew turns developer mode on by
# itself the first time one is called, once, with a warning in the middle of the
# log; asking for it up front keeps that out of the way, which is what stage A
# does for `brew bottle` for the same reason.
brew developer on
if ! brew test "$HOMEBREW_TAP/qmdmm" >"$test_log" 2>&1; then
  echo "::error::the recipe's own test failed against the installed package"
  sed -e 's/^/  test| /' "$test_log"
  exit 1
fi

# ... and the same command has to come back non-zero on a block that cannot
# pass, or the reading above would be one that cannot go red. The mutation is
# the block's own subject - the program it names, removed from the equation -
# and the guard right after it is what keeps this a mutation rather than a
# silently vacuous control if the block is ever rewritten to name something else.
sed -e 's|bin/"QMdmmServer6"|bin/"QMdmmServer6-not-installed"|' \
  /tmp/qmdmm.rb.poured > "$tap_dir/Formula/qmdmm.rb"
if ! grep -q 'QMdmmServer6-not-installed' "$tap_dir/Formula/qmdmm.rb"; then
  echo "::error::the mutation did not reach the recipe's test block, so the negative control below would prove nothing. The block as it stands:"
  sed -n '/^  test do/,/^  end/p' /tmp/qmdmm.rb.poured
  exit 1
fi
bad_log=/tmp/brew-test-mutated.log
if brew test "$HOMEBREW_TAP/qmdmm" >"$bad_log" 2>&1; then
  echo "::error::the recipe's own test passed with a program that is not installed in it, so this stage is not reading the block"
  sed -e 's/^/  test| /' "$bad_log"
  exit 1
fi
echo "the mutated block is rejected, so the reading above can go red"
# The poured copy back, so that what the summary below reads is what was poured.
cp /tmp/qmdmm.rb.poured "$tap_dir/Formula/qmdmm.rb"

{
  echo
  echo '### The recipe test block'
  echo
  echo 'The `test do` block in the recipe, run by `brew test` - the one command'
  echo 'that executes it, and the one thing `brew install` does not do. Run'
  echo 'against the tap copy stage A wrote, i.e. the block a user gets, and'
  echo 'followed by the same command against a mutated copy as the control that'
  echo 'says this reading can go red.'
  echo
  echo '`brew test` against the poured package, which has to come back 0:'
  echo
  echo '```'
  cat "$test_log"
  echo '```'
  echo
  echo '... and the same command against the copy whose block names a program'
  echo 'that is not installed, which has to come back non-zero, and for the'
  echo 'reason the mutation describes. Its own last words:'
  echo
  echo '```'
  if [ -s "$bad_log" ]; then tail -20 "$bad_log"; else echo '(it wrote nothing about it, so the exit status is the whole of the report)'; fi
  echo '```'
  # `tee` rather than `>>`: a step summary is rendered for a browser, so a
  # reading written there alone cannot be read back out of a run's log. Both of
  # these are the evidence for a criterion, so they go to both.
} | tee -a "$GITHUB_STEP_SUMMARY"

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
  brew list --versions qtbase qtdeclarative qtwebsockets
  brew list --versions qt || echo 'the qt meta formula is not installed'
  brew deps --installed --include-build "$HOMEBREW_TAP/qmdmm" || true
  echo '```'
} >> "$GITHUB_STEP_SUMMARY"
