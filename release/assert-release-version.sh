#!/usr/bin/env bash
#
# Assert that the version a release names is the version its recipes pin.
#
# A release states its version in four places that are written by hand and read
# by nobody:
#
#   * the tag name, which is what the release is called and what the `.dmg` is
#     checked against;
#   * `project(... VERSION ...)` in QMdmm's root CMakeLists, which is where the
#     deb and rpm versions come from - cpack reads it - and where the Homebrew
#     and macOS lines read theirs from too;
#   * `pkgver` in `packaging/arch/PKGBUILD`, which is what makepkg stamps the
#     Arch package with;
#   * `pkgver` in `packaging/alpine/APKBUILD`, which is what abuild stamps the
#     apk packages with.
#
# The last two are the reason this exists. `ci/pack-pac.sh` and
# `ci/pack-apk.sh` build `packaging/*` recipes and the recipes carry their own
# version, so a release dispatched with 0.0.2 and recipes left saying 0.0.1
# ships Arch and Alpine packages stamped 0.0.1 beside deb and rpm packages
# stamped 0.0.2 - and every stage of the run is green, because no stage reads a
# version and nothing downstream compares two of them. `.SRCINFO` is here for
# the same reason one level down: it restates `pkgver` and the tarball name, so
# editing the recipe and not it leaves a file that disagrees with its
# neighbour and is copied into the build directory.
#
# The comparison is against the TAG'S TREE and not against the tag's name. They
# are the same string on every release so far, but they are two different facts,
# and a tag named 0.0.2 on a tree saying 0.0.3 would satisfy "the name matches
# the name" while shipping 0.0.3 from cpack.
#
# Why this is not an assertion inside the two pack scripts: those scripts are
# also the daily smoke run's, and the smoke run packages `main` rather than a
# tag. A version check there would turn every version bump on main into a red
# daily run until somebody edited a recipe in this repository - which is a
# coupling between two repositories that nothing asked for. A release is the
# only caller that has a version to compare against, so the check lives on the
# release's own path, in the guard, before anything is built or signed.
#
#   env: REVISION   the tag this release packages (required)
#        QMDMM_REPO the upstream to read (default: the QMdmm repository)
set -euo pipefail
cd "$(dirname "$0")/.."

REPO="${QMDMM_REPO:-https://github.com/QMdmm/QMdmm.git}"
: "${REVISION:?REVISION is required - the tag to release, e.g. 0.0.2}"

# Which spelling was typed is not the question, and a leading `v` is Homebrew's
# habit rather than a version component - pack-brew.sh strips it the same way.
REV="${REVISION#refs/tags/}"
WANT="${REV#v}"
if [ -z "$WANT" ]; then
  echo "refusing: REVISION is empty once refs/tags/ and a leading v are stripped" >&2
  exit 1
fi

# The recipes are read out of this repository's own checkout, which is the copy
# the pack rows will use.
recipe() {  # recipe <file> <sed-program> <what it is>
  local file="$1" prog="$2" what="$3" got=""
  if [ ! -f "$file" ]; then
    echo "refusing: $file does not exist, so $what cannot be read" >&2
    exit 1
  fi
  got=$(sed -n "$prog" "$file" | head -1)
  if [ -z "$got" ]; then
    # Empty is not "nothing to check": it means the field moved or was renamed,
    # and a comparison against an empty string would agree with a version of "".
    echo "refusing: $file declares no $what" >&2
    exit 1
  fi
  printf '%s' "$got"
}

arch=$(recipe packaging/arch/PKGBUILD 's/^pkgver=//p' pkgver)
srci=$(recipe packaging/arch/.SRCINFO 's/^[[:space:]]*pkgver = //p' pkgver)
apk=$(recipe packaging/alpine/APKBUILD 's/^pkgver=//p' pkgver)

# Read the tree the tag points at, rather than trusting the name. Shallow and
# one file: this is a question about a number, not a checkout.
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
git init -q "$W/src"
git -C "$W/src" remote add origin "$REPO"
if ! git -C "$W/src" fetch --depth 1 origin "refs/tags/$REV" 2>"$W/err"; then
  echo "refusing: cannot fetch refs/tags/$REV from $REPO" >&2
  sed 's/^/  /' "$W/err" >&2
  exit 1
fi
# The peeled commit, because FETCH_HEAD is the TAG OBJECT for an annotated tag
# and `<tag object>:CMakeLists.txt` is not a path that resolves.
if ! sha=$(git -C "$W/src" rev-parse 'FETCH_HEAD^{commit}' 2>"$W/err"); then
  echo "refusing: refs/tags/$REV does not peel to a commit" >&2
  sed 's/^/  /' "$W/err" >&2
  exit 1
fi
if ! git -C "$W/src" show "$sha:CMakeLists.txt" > "$W/CMakeLists.txt" 2>"$W/err"; then
  echo "refusing: $REV ($sha) carries no root CMakeLists.txt" >&2
  sed 's/^/  /' "$W/err" >&2
  exit 1
fi
tree=$(awk '/^project\(/ { in_project = 1 } \
            in_project && /VERSION/ { \
              sub(/.*VERSION[ \t]+/, ""); sub(/[ \t].*/, ""); print; exit \
            }' "$W/CMakeLists.txt")
if [ -z "$tree" ]; then
  echo "refusing: $REV's root CMakeLists.txt declares no project VERSION" >&2
  exit 1
fi

echo "=== the version this release names, and where each copy of it says so ==="
printf '  %-46s %s\n' "the tag"                       "$REV"
printf '  %-46s %s\n' "  (as a version)"              "$WANT"
printf '  %-46s %s\n' "$REV:CMakeLists.txt"           "$tree"
printf '  %-46s %s\n' "packaging/arch/PKGBUILD"       "$arch"
printf '  %-46s %s\n' "packaging/arch/.SRCINFO"       "$srci"
printf '  %-46s %s\n' "packaging/alpine/APKBUILD"     "$apk"
echo

fail=0
for pair in "the tag's tree|$tree" \
            "packaging/arch/PKGBUILD|$arch" \
            "packaging/arch/.SRCINFO|$srci" \
            "packaging/alpine/APKBUILD|$apk"; do
  who="${pair%%|*}"; got="${pair#*|}"
  if [ "$got" != "$WANT" ]; then
    echo "!! $who says '$got', and this release is '$WANT'"
    fail=1
  fi
done

if [ "$fail" != 0 ]; then
  cat >&2 <<EOF
!! The recipes in this repository and the version being released disagree.
   Those two numbers are written by hand and read by nothing: the deb, rpm,
   Homebrew and macOS lines take their version from the tagged tree, while
   packaging/arch and packaging/alpine carry one of their own - so a run that
   reached the publish stage in this state would put packages of two different
   versions in the same published repository, with every stage green.

   Sync the recipes to the release's version before dispatching:

     packaging/arch/PKGBUILD       pkgver=$WANT
     packaging/arch/.SRCINFO       pkgver = $WANT   (and the source = line's tarball name)
     packaging/alpine/APKBUILD     pkgver=$WANT   (and the sha512sums line's tarball name)

   The two checksum blocks are re-derived by the build (updpkgsums / abuild
   checksum) and do not have to be right here, but the NAMES in them do: they
   are read as written, before anything recomputes them.
EOF
  exit 1
fi

echo "OK: the tag, the tagged tree and all three recipe files say $WANT"
