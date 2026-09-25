#!/usr/bin/env bash
#
# Stage C for the Homebrew line, in one file: bring the same clean runner state
# stage B starts from, pour the same formula, and fetch the QMdmm sources the
# consumer project builds against what was installed.
#
# See dev-deb.sh for what stage C asks and why the toolchain is deliberately
# plain. Two things are macOS's own:
#
#   * There is no `-dev` package to install separately. One formula carries the
#     programs, the headers and the CMake package together, so what this stage
#     tests is not "a second package resolves" but "what the one package
#     installed is enough to build against" - the same narrowing the Arch line
#     makes, for the same reason (no component split).
#   * `brew link` puts a keg's bin/ and lib/ into the prefix but leaves
#     lib/cmake where it is, so a consumer does not find the CMake package by
#     itself. build-verify-macos.sh therefore has to name the prefixes, which is
#     the one place this line diverges from the four Linux ones by more than
#     vocabulary.
set -euxo pipefail

for module in qt qtbase qtdeclarative qtwebsockets; do
  if ls /opt/homebrew/opt 2>/dev/null | grep -qx "$module"; then
    echo "::error::Qt ($module) is already installed on this runner, so what the dev face provides could not be told from what the image provided"
    ls -l "/opt/homebrew/opt/$module"
    exit 1
  fi
done

brew tap "$HOMEBREW_TAP"
brew trust --tap "$HOMEBREW_TAP"
tap_dir=$(brew --repo "$HOMEBREW_TAP")
test -f pkgs/qmdmm.rb
install -m 644 pkgs/qmdmm.rb "$tap_dir/Formula/qmdmm.rb"

mkdir -p serve
cp pkgs/bottles/*.bottle.tar.gz serve/
serve_dir=$PWD/serve
bottle_file=$(basename "$(ls pkgs/bottles/*.bottle.tar.gz | head -1)")
port=${BOTTLE_ROOT_URL##*:}
if command -v python3 >/dev/null; then
  python3 -m http.server "$port" --directory "$serve_dir" >/tmp/httpd.log 2>&1 &
else
  ruby -run -e httpd "$serve_dir" -p "$port" >/tmp/httpd.log 2>&1 &
fi
httpd_pid=$!
trap 'kill "$httpd_pid" 2>/dev/null || true' EXIT
for _ in $(seq 1 40); do
  curl -fsS -o /dev/null "$BOTTLE_ROOT_URL/$bottle_file" && break
  sleep 0.25
done
curl -fsS -o /dev/null "$BOTTLE_ROOT_URL/$bottle_file" || {
  echo "::error::the bottle is not being served at $BOTTLE_ROOT_URL/$bottle_file"
  sed -e 's/^/  httpd| /' /tmp/httpd.log
  exit 1
}

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

# The toolchain this stage is allowed to assume: what the runner image already
# carries, which on macOS is Homebrew's cmake and ninja rather than anything a
# base image would have been asked to install. The Linux lines get their
# toolchain from a base-image script that fails if the install fails; here there
# is nothing to install, so the check is that the image really does carry them -
# and the paths are printed as well, because an out-of-band cmake earlier on
# PATH is exactly what would shadow the one being counted on.
for tool in cmake ninja git; do
  if ! command -v "$tool" >/dev/null; then
    echo "::error::$tool is not on this runner, and this stage does not install a toolchain"
    exit 1
  fi
done
{
  echo '### The build toolchain'
  echo
  echo '```'
  which -a cmake ninja git
  cmake --version | head -1
  ninja --version
  echo '```'
} >> "$GITHUB_STEP_SUMMARY"

{
  echo '### Everything present after installing only qmdmm'
  echo
  echo '```'
  brew list --versions | sort
  echo '```'
  echo
  echo 'The CMake packages the consumer will be pointed at, in the order it is'
  echo 'given them - the Homebrew prefix first, because that is the only place'
  echo "Qt's modules are all visible together:"
  echo
  echo '```'
  echo "$(brew --prefix)/lib/cmake"
  for dep in $(brew deps --installed "$HOMEBREW_TAP/qmdmm"); do
    p=$(brew --prefix "$dep")
    [ -d "$p/lib/cmake" ] && echo "$p/lib/cmake"
  done
  echo '```'
} >> "$GITHUB_STEP_SUMMARY"

git init qmdmm-src
git -C qmdmm-src remote add origin "$QMDMM_REPO"
git -C qmdmm-src fetch --depth 1 origin "$QMDMM_REF"
git -C qmdmm-src checkout --detach FETCH_HEAD
echo "QMdmm HEAD: $(git -C qmdmm-src log --oneline -1)"
