#!/usr/bin/env bash
#
# Stage B's first half for the macOS line, in one file: assert the runner really
# has no Qt, mount stage A's image and copy the application out of it onto this
# machine the way the readme tells a user to.
#
# The counterpart is ci/runtime-brew.sh, and the difference between the two is
# the whole difference between the two macOS shapes. The Homebrew line installs a
# package and checks that it was *poured* rather than built; this line has no
# package manager in the picture at all - it has a disk image and a bundle that
# carries its own Qt - so what would be "the pour" here is "the copy", and what
# would be "the declared dependency" is "nothing outside the bundle".
#
# See runtime-deb.sh for why stage B starts clean and installs by name. On macOS
# there is no container to be clean in, so a fresh runner takes its place - with
# one difference worth keeping in view: a container starts out empty, while a
# macOS runner image already carries Homebrew, cmake and ninja in /opt/homebrew.
# Qt is the one package that would make this stage vacuous and it is *not* in the
# image, which is why "no Qt before the copy" is asserted below rather than
# believed. Here it is worth more than it is on the Homebrew line: a bundle whose
# Qt was somehow satisfied by the machine would pass the dependency assertion
# without being self-contained at all.
set -euxo pipefail

if ls /opt/homebrew/opt 2>/dev/null | grep -qx qt; then
  echo "::error::Qt is already installed on this runner, so a self-contained bundle could not be told from one that borrowed the machine's Qt"
  ls -l /opt/homebrew/opt/qt
  exit 1
fi
for tool in qmake6 qtpaths6 moc; do
  if command -v "$tool" >/dev/null; then
    echo "::error::$tool is on PATH before anything was installed"
    exit 1
  fi
done
echo "no Qt on this runner, which is what stage B starts from"

dmg=$(ls pkgs/*.dmg | head -1)
test -n "$dmg"
echo "image: $dmg"

# The mount is torn down by the trap whatever happens. An image left attached
# would make a later step fail for a reason of this one's making, which is the
# same reason the .dmg line tears it down explicitly on the way out.
mkdir -p /tmp/mnt
hdiutil attach -nobrowse -readonly "$dmg" -mountpoint /tmp/mnt
mounted=1
cleanup() { [ "${mounted:-0}" = 1 ] && hdiutil detach /tmp/mnt >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "### the image's top level"
ls -A /tmp/mnt | sed -e 's/^/  /'

# Copied, not run from the mount. The readme in the image tells a user to drag
# the application across, and this stage does the same thing on purpose: it is
# the only way the path the application actually runs from - and therefore the
# only way the framework lookups inside its Info.plist are exercised - as a
# user's own copy would exercise it. /Applications is writable on this image.
if [ -e /Applications/QMdmm6.app ]; then
  echo "::error::/Applications/QMdmm6.app already exists on this runner, so the copy below would not be the reading it is meant to be"
  exit 1
fi
cp -R /tmp/mnt/QMdmm6.app /Applications/

hdiutil detach /tmp/mnt >/dev/null
mounted=0

# Read back rather than assumed, and the executables specifically: everything
# ci/runtime-verify-macos.sh does with MACOS_FACE=dmg addresses this directory,
# and a copy that lost a mode bit or a program would otherwise surface there as
# a launch failure.
app=/Applications/QMdmm6.app
for prog in QMdmm6 QMdmmServer6 QMdmmBot6; do
  if [ ! -x "$app/Contents/MacOS/$prog" ]; then
    echo "::error::$app/Contents/MacOS/$prog is missing or not executable"
    exit 1
  fi
done

{
  echo '### The application as copied onto this machine'
  echo
  echo '```'
  ls -l "$app/Contents/MacOS"
  echo '```'
  echo
  echo 'Qt is not installed on this runner, and nothing below installs it:'
  echo 'if the programs run, they ran out of the bundle.'
} >> "$GITHUB_STEP_SUMMARY"
