#!/usr/bin/env bash
#
# Put this release's formula into the tap.
#
# The formula that goes in is FETCHED FROM THE SITE rather than taken from the
# artifact the publish job staged. The tap has to carry the bytes a consumer
# can get, and fetching them means there is one copy of the file rather than
# two that can disagree - which is the same reason stage A taps the repository
# instead of keeping a formula of its own.
#
# Before anything is written, EVERY bottle that formula names is downloaded and
# hashed against the checksum in its own bottle block. One bottle per macOS
# version, and the check is per bottle: a pour is per machine, so a block whose
# macOS 15 line pointed at a bottle that was not there would build from source
# for macOS 15 users alone, with a warning, while every stage of this workflow
# was green for everybody else. That is the failure the whole line exists to
# catch, and one bottle is no longer enough to catch it.
#
# Why this is a job of its own, with a credential: the tap is a different
# repository, and no token a workflow is issued can write outside the one it
# runs in. CROSS_REPO_TOKEN is scoped to the tap and to the product repository
# and to nothing else.
#
# What this stage may NOT do is rewrite the tap. That formula is hand-written -
# the dependency list, the reasoning about qttools, the test block and its
# comments are somebody's decisions - and what a release adds to it is a pin and
# a bottle block. So the change is bounded rather than trusted: the only lines
# this may remove are the old `url`, `sha256` and `version` lines, and the only
# lines it may add are those three plus the block itself. An overwrite that
# dropped a comment fails here, which is the difference between publishing a
# bottle and quietly editing a recipe.
#
# usage: publish-tap.sh
# env:   PAGES        (the site the bottle and the formula were published to)
#        QMDMM_REF    (the tag this release packages)
#        HOMEBREW_TAP (Homebrew's spelling, e.g. QMdmm/qmdmm)
#        GH_TOKEN     (CROSS_REPO_TOKEN; absent is a hard failure)
set -euo pipefail

if [ -z "${GH_TOKEN:-}" ]; then
  echo "::error::GH_TOKEN is empty. It carries CROSS_REPO_TOKEN, the one credential here that can write outside this repository; without it the tap cannot be updated, and a bottle nobody's formula points at has not been published."
  exit 1
fi
command -v git >/dev/null || { echo "::error::git is not installed in this image"; exit 1; }
command -v curl >/dev/null || { echo "::error::curl is not installed in this image"; exit 1; }
PAGES="${PAGES:?}"; QMDMM_REF="${QMDMM_REF:?}"; HOMEBREW_TAP="${HOMEBREW_TAP:?}"

# The tap in Homebrew's spelling (`owner/name`, with `brew tap` dropping the
# homebrew- prefix) is what the scripts that tap it take; the repository is the
# `homebrew-<name>` one. Derived rather than listed a second time, so the two
# cannot come apart.
owner="${HOMEBREW_TAP%%/*}"; name="${HOMEBREW_TAP##*/}"
[ "$owner" != "$name" ] || { echo "::error::HOMEBREW_TAP='$HOMEBREW_TAP' is not owner/name"; exit 1; }
slug="$owner/homebrew-$name"
echo "tap: $HOMEBREW_TAP -> $slug"

W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT

# --- the formula, as published -------------------------------------------
# Fetched with a cache-buster, and the reason is not politeness: the publish job
# waits until Pages serves THIS run's publish.json, but a CDN caches per URL,
# and a stale copy of the formula compares equal to what the tap already holds.
# That is the one way this stage could go green having published nothing.
FORMULA_URL="$PAGES/brew/qmdmm.rb"
if ! curl -fsSL --max-time 60 \
        -H 'Cache-Control: no-cache' -H 'Pragma: no-cache' \
        "$FORMULA_URL?cb=${RANDOM}${RANDOM}" -o "$W/qmdmm.rb"; then
  echo "::error::cannot fetch $FORMULA_URL. The publish job stages it there; without it there is nothing to put in the tap."
  exit 1
fi
echo "fetched $FORMULA_URL ($(wc -c < "$W/qmdmm.rb" | tr -d ' ') bytes)"

n=$(grep -cE '^[[:space:]]*root_url[[:space:]]' "$W/qmdmm.rb" || true)
[ "$n" = 1 ] || {
  echo "::error::the published formula has $n root_url lines, expected exactly 1 - it is not the one this workflow wrote"; exit 1; }
grep -qE "^[[:space:]]*root_url \"$PAGES/brew\"\$" "$W/qmdmm.rb" || {
  echo "::error::the published formula's root_url is not $PAGES/brew, so its bottle lives somewhere this workflow did not choose:"
  grep -E '^[[:space:]]*root_url' "$W/qmdmm.rb"; exit 1; }

# The tags and their checksums, read off the block rather than assumed. One line
# per macOS version this release bottled, and the reading is that every
# `sha256 cellar:` line in the block yielded a pair: a line this stage could not
# parse is a line whose bottle would never be verified, and skipping it quietly
# is exactly how one macOS version stops being served without anyone noticing.
block=$(sed -n '/^[[:space:]]*bottle do/,/^[[:space:]]*end/p' "$W/qmdmm.rb")
[ -n "$block" ] || { echo "::error::the published formula has no bottle block:"; cat "$W/qmdmm.rb"; exit 1; }
pairs=$(printf '%s\n' "$block" \
  | sed -nE 's/^[[:space:]]*sha256[[:space:]]+cellar: [^,]*, ([a-z0-9_]+): "([0-9a-f]{64})".*/\1 \2/p')
count=$(printf '%s\n' "$pairs" | grep -c . || true)
n_lines=$(printf '%s\n' "$block" | grep -cE '^[[:space:]]*sha256[[:space:]]+cellar:' || true)
if [ "$n_lines" -lt 1 ]; then
  echo "::error::no bottle line in the published formula's block:"; printf '%s\n' "$block"; exit 1
fi
if [ "$count" != "$n_lines" ]; then
  echo "::error::the block has $n_lines sha256 cellar line(s) but only $count of them could be read as tag/checksum. The ones this stage cannot read are bottles nobody would verify:"
  printf '%s\n' "$block"; exit 1
fi
if [ "$(printf '%s\n' "$pairs" | awk '{print $1}' | sort -u | grep -c .)" != "$count" ]; then
  echo "::error::the block names the same bottle tag twice:"; printf '%s\n' "$pairs"; exit 1
fi
echo "bottle tags in the published formula: $(printf '%s' "$pairs" | awk '{printf "%s ", $1}')"

# The source pin has to be this release's tag. The tap's whole claim is that the
# recipe a user gets builds the thing this release is, and a formula that pinned
# a different tag while carrying this bottle would pass every other check here.
grep -qE "^[[:space:]]*url \"[^\"]*/archive/refs/tags/$QMDMM_REF\.tar\.gz\"\$" "$W/qmdmm.rb" || {
  echo "::error::the published formula does not pin $QMDMM_REF:"
  grep -E '^[[:space:]]*url ' "$W/qmdmm.rb"; exit 1; }

# --- the bottles that formula names --------------------------------------
# The name is what Homebrew builds the URL out of: name-version.tag.bottle.tar.gz,
# where the version is the one it parses out of the url - which strips a leading
# `v`. Getting this wrong is a 404 at pour time rather than here, so every file
# is fetched and hashed rather than assumed to be there.
version="${QMDMM_REF#v}"
verified=0
while read -r tag hash; do
  [ -n "$tag" ] || continue
  bottle="qmdmm-$version.$tag.bottle.tar.gz"
  BOTTLE_URL="$PAGES/brew/$bottle"
  if ! curl -fsSL --max-time 300 \
          -H 'Cache-Control: no-cache' -H 'Pragma: no-cache' \
          "$BOTTLE_URL?cb=${RANDOM}${RANDOM}" -o "$W/$bottle"; then
    echo "::error::$BOTTLE_URL cannot be fetched, so the formula being published names a bottle that is not there - for $tag alone. A pour on that macOS would fall back to building from source and say so only in a warning, while every other macOS poured the bottle. Check that this tag's row of the release built one and that publish-brew.sh staged it."
    exit 1
  fi
  got=$(shasum -a 256 "$W/$bottle" | awk '{print $1}')
  if [ "$got" != "$hash" ]; then
    echo "::error::the bottle at $BOTTLE_URL hashes to $got, and the formula's block says $hash (tag $tag). A pour on that macOS would reject it (or fall back to a source build); the two were not produced together."
    exit 1
  fi
  echo "verified: $bottle  $got  ($(wc -c < "$W/$bottle" | tr -d ' ') bytes) matches the block"
  verified=$((verified + 1))
done < <(printf '%s\n' "$pairs")
[ "$verified" = "$count" ] || { echo "::error::$count bottle tag(s) in the block, $verified verified"; exit 1; }

# --- the tap --------------------------------------------------------------
# Cloned rather than driven through the contents API, so that what is compared
# and what is pushed is a git object, and so that the read-back below can be a
# fetch rather than a second API call.
if ! git clone -q --depth 1 "https://x-access-token:${GH_TOKEN}@github.com/${slug}.git" "$W/tap"; then
  echo "::error::cannot clone $slug. The token has to be able to read and write it."
  exit 1
fi
branch=$(git -C "$W/tap" rev-parse --abbrev-ref HEAD)
old="$W/tap/Formula/qmdmm.rb"
[ -f "$old" ] || {
  echo "::error::$slug carries no Formula/qmdmm.rb. The tap is where the hand-written recipe lives; a release adds a pin and a bottle block to it rather than introducing it."
  exit 1; }

if cmp -s "$old" "$W/qmdmm.rb"; then
  echo "the tap already carries exactly this formula - nothing to publish"
  {
    echo '### The Homebrew tap'
    echo
    echo "\`$slug\` already carries this release's formula byte for byte"
    echo "(\`$version\`, bottle tag(s) \`$(printf '%s' "$pairs" | awk '{printf "%s ", $1}')\`),"
    echo 'so it was left alone. Every bottle its block names was still fetched'
    echo 'and hashed above, which is the part that could have gone stale.'
  } >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
  exit 0
fi

diff_lines=$({ diff -u "$old" "$W/qmdmm.rb" || true; } | tail -n +3)
# An added blank line is part of the block rather than a change to the recipe:
# `brew bottle --merge --write` puts one after the block it writes, and a rule
# that rejected it would fail every release. A REMOVED blank line is still
# refused, because that would mean this is deleting something of the tap's.
# A `rebuild` line would be refused by the rule below as though it were a change
# to the recipe. It is not that: it is one line of the block, and the one line of
# it that must never be published from here. Homebrew numbers a bottle when the
# tap's own formula already carries the version being bottled - which is this
# one's case, since it pins the tag being released - and it spells the number as
# a dotted `.1` on the end of the filename and a `rebuild 1` beside it.
# Versions here are semver, so a `.1` against the version reads as part of it.
# `pack-brew.sh` passes --no-rebuild for exactly this reason; this is where it
# would surface if that flag stopped doing what it says.
if printf '%s\n' "$diff_lines" | grep -qE '^\+[[:space:]]*rebuild[[:space:]]'; then
  echo "::error::the bottle block being published carries a rebuild number:"
  printf '%s\n' "$diff_lines" | grep -E '^\+[[:space:]]*rebuild[[:space:]]' | sed -e 's/^/  tap| /'
  echo "   Bottle versions here are semver, so a dotted '.1' reads as part of the"
  echo "   version rather than as a second build of the same one. pack-brew.sh"
  echo "   asks Homebrew for --no-rebuild; this says that stopped being true."
  exit 1
fi

bad=$(printf '%s\n' "$diff_lines" | awk '
  /^-/  { if ($0 !~ /^-[ \t]*(url|sha256|version)[ \t]/) print; next }
  /^\+/  { if ($0 ~  /^\+[ \t]*(url|sha256|version)[ \t]/) next
           if ($0 ~  /^\+[ \t]*$/)                         next
           if ($0 ~  /^\+[ \t]*bottle do[ \t]*$/)           next
           if ($0 ~  /^\+[ \t]*root_url "/)                 next
           if ($0 ~  /^\+[ \t]*sha256 cellar:/)             next
           if ($0 ~  /^\+[ \t]*end[ \t]*$/)                 next
           print; next }
')
if [ -n "$bad" ]; then
  echo "::error::publishing this bottle would change lines the tap's formula does not own:"
  printf '%s\n' "$bad" | sed -e 's/^/  tap| /'
  echo "   Only the url / sha256 / version lines and the bottle block may differ."
  echo "   A root_url among them means the site this release publishes to is not"
  echo "   the one the tap already points at: that is an address move, and it is"
  echo "   somebody's decision to make in the tap rather than a release's to make"
  echo "   silently."
  echo "   What the tap holds and what this release produced have diverged:"
  printf '%s\n' "$diff_lines" | sed -e 's/^/  diff| /'
  exit 1
fi
echo "--- the change, bounded to the pin and the block ---"
printf '%s\n' "$diff_lines" | sed -e 's/^/  /'

cp "$W/qmdmm.rb" "$old"
git -C "$W/tap" add Formula/qmdmm.rb
git -C "$W/tap" -c user.name="Neve M. Nguyen" -c user.email="nemn9852@agent.qq.com" \
    commit -q -m "qmdmm $version: bottles for $(printf '%s' "$pairs" | awk '{printf "%s ", $1}')($QMDMM_REF)"
# No --force and no --force-with-lease: if the tap moved under this run, that is
# somebody else's commit and this stage must not decide to throw it away.
git -C "$W/tap" push -q origin "HEAD:refs/heads/$branch"

# Read back off the remote rather than off the push's exit status: the question
# is what the tap now holds, and a fetch is what answers it. `git hash-object`
# is the same object hash the clone would report, so this is an identity rather
# than a similarity.
git -C "$W/tap" fetch -q origin "$branch"
want=$(git -C "$W/tap" hash-object "$W/qmdmm.rb")
got_blob=$(git -C "$W/tap" rev-parse "FETCH_HEAD:Formula/qmdmm.rb")
if [ "$want" != "$got_blob" ]; then
  echo "::error::the tap's Formula/qmdmm.rb is blob $got_blob after the push, and the formula this run verified is $want"; exit 1
fi
echo "pushed to $slug@$branch: Formula/qmdmm.rb is now blob $got_blob"

{
  echo '### The Homebrew tap'
  echo
  echo "\`$slug\` now carries this release's formula on \`$branch\` (blob"
  echo "\`$got_blob\`, read back off the remote after the push): \`$version\`,"
  echo 'and a bottle for each of these macOS versions -'
  echo
  echo '```'
  printf '%s\n' "$pairs" | awk -v v="$version" '{printf "%s  qmdmm-%s.%s.bottle.tar.gz\n", $1, v, $1}'
  echo '```'
  echo
  echo 'Every one of those was fetched from the site and hashed against the'
  echo 'checksum beside it before anything was written, so what the tap now'
  echo 'points at is what the site is serving.'
  echo
  echo 'The change, bounded to the pin and the bottle block:'
  echo
  echo '```diff'
  printf '%s\n' "$diff_lines"
  echo '```'
  echo
  echo 'A user installing from this tap now pours a bottle for their own macOS'
  echo 'rather than building from source.'
} >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
