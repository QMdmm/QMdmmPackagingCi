#!/usr/bin/env bash
#
# Stage A for the Homebrew line, one row per macOS: tap the repository that
# holds the formula, re-derive its source pin for the ref this run was given,
# install it from source with --build-bottle, and bottle it.
#
# What a row produces is one bottle, the JSON that describes it (which is what
# the merge stage consumes and nothing else does), the pinned formula, and a
# manifest naming this row's own tag. It deliberately writes NO bottle block:
# a block carries one checksum per macOS version and the formula a user gets
# carries all of them, so the block is assembled once, from every row's JSON,
# by ci/merge-brew.sh. A row that merged its own would be writing a formula
# whose block says "this bottle, on this macOS" - which is the one thing a
# single row knows and the one thing the published recipe must not say.
#
# There is no `base-image-brew.sh` behind this: the macOS runner image already
# has Homebrew, git, cmake and ninja, and Qt is *not* in it (the toolset's
# brew.common_packages has no qt), which is what makes "install from source"
# mean what it says here rather than quietly reusing something preinstalled.
#
# The formula lives in QMdmm/homebrew-qmdmm and not in this repository, on
# purpose: this stage must verify the recipe a user gets, and a second copy
# would be a copy that could drift. Everything below therefore works on the
# tap's own checkout of it.
#
# env: MACOS_TAG - the bottle tag this row's runner is expected to produce,
#                  e.g. arm64_sequoia. Declared by the workflow's matrix and
#                  asserted below against Homebrew's own answer.
set -euxo pipefail

# `brew bottle` is a developer command, and Homebrew turns developer mode on by
# itself the first time one is called - once, with a warning, in the middle of
# this stage's log. Asking for it up front keeps that out of the way. It is also
# what keeps the warning out of the tag reading below, which parses stdout.
brew developer on

# The row's premise, as a reading rather than as a label. A bottle's tag is the
# *producing* machine's macOS version and it is the compatibility floor - a
# macOS older than the runner cannot pour the bottle - so a row whose runner is
# not the macOS it claims would publish a bottle labelled for a system it was
# not built on, and every later stage would agree with the label, because every
# later stage reads the tag out of the block this run writes. Nothing downstream
# can catch that; this can.
#
# The comparison is against Homebrew's own `Utils::Bottles.tag`, not against a
# table of codenames kept here: the question is "what would `brew bottle` name
# this machine's bottle", so the answer has to come from the same place the name
# does. `2>/dev/null` because a dev command writes its own notices to stderr and
# this reads stdout.
: "${MACOS_TAG:?this row must declare the bottle tag of its runner, e.g. arm64_sequoia}"
system_tag=$(brew ruby -e 'require "utils/bottles"; print Utils::Bottles.tag' 2>/dev/null)
if [ "$system_tag" != "$MACOS_TAG" ]; then
  echo "::error::this row declares $MACOS_TAG, but Homebrew names this machine's bottle $system_tag ($(uname -m), macOS $(sw_vers -productVersion)). A bottle tagged for a macOS it was not built on is the one thing no later stage can detect: they all read the tag from the bottle itself."
  exit 1
fi
echo "this row's tag: $MACOS_TAG, which is what Homebrew computes for $(sw_vers -productVersion) here"

# Cloned rather than faked. The local verification could write a formula
# straight into Library/Taps (an installed tap is only a directory,
# `Tap#installed?` asks `path.directory?`), but now that the tap exists there
# is no reason to: cloning is the path a user takes, and it is also what
# `brew bottle` requires - it refuses a formula that is not from an installed
# tap ("Formula not from core or any installed taps").
brew tap "$HOMEBREW_TAP"
# Homebrew 6.0 refuses to load a formula from a tap it has not been told to
# trust, and that refusal comes before anything else can run.
brew trust --tap "$HOMEBREW_TAP"

tap_dir=$(brew --repo "$HOMEBREW_TAP")
formula="$tap_dir/Formula/qmdmm.rb"
test -f "$formula"

# The source pin. The committed formula points at a released tag; a run
# packages whatever QMDMM_REF says, so the pin is re-derived from the ref that
# was actually fetched. A tag ref keeps the tag url - which is then the shape
# the tap ships, character for character - and only its sha256 is re-measured.
# A branch or a commit has no tag tarball, so the url has to become
# .../archive/<full-sha>.tar.gz, and the version, which Homebrew normally
# detects from the url, has to be read out of the source tree and stated. The
# Arch line's `updpkgsums` and the Alpine line's `abuild checksum` do the same
# job: the committed pin records the ref that was verified locally, and a run
# re-derives it.
git init qmdmm-src
git -C qmdmm-src remote add origin "$QMDMM_REPO"
git -C qmdmm-src fetch --depth 1 origin "$QMDMM_REF"
# A bare ref name writes FETCH_HEAD and creates no ref of its own, and the check
# further down (`git describe --tags`) reads local refs - so a ref that names a
# tag has to be fetched by its full refspec as well, or that check cannot see
# the tag at all and the tag shape is never chosen. Silently: the fallback below
# is a well-formed formula, and it is only a *different* recipe from the one the
# tap ships. The first dispatched release went that way, and
# release/publish-tap.sh is where it surfaced.
if git -C qmdmm-src ls-remote --exit-code --tags --refs origin "refs/tags/$QMDMM_REF" >/dev/null 2>&1; then
  git -C qmdmm-src fetch --depth 1 origin "+refs/tags/$QMDMM_REF:refs/tags/$QMDMM_REF"
fi

git -C qmdmm-src checkout --detach FETCH_HEAD
echo "QMdmm HEAD: $(git -C qmdmm-src log --oneline -1)"

# `^{commit}`, because for an annotated tag FETCH_HEAD is the tag *object* - a
# sha that is in no branch's history and that no other archive URL is built
# from. This value becomes the url below and is printed as a commit, so it has
# to be one.
sha=$(git -C qmdmm-src rev-parse "FETCH_HEAD^{commit}")
web=${QMDMM_REPO%.git}
version=$(awk '/^project\(/ { in_project = 1 } \
              in_project && /VERSION/ { \
                sub(/.*VERSION[ \t]+/, ""); sub(/[ \t].*/, ""); print; exit \
              }' qmdmm-src/CMakeLists.txt)
if [ -z "$version" ]; then
  echo "::error::no VERSION found in qmdmm-src/CMakeLists.txt"
  exit 1
fi

# `describe` and not a comparison of names: it can only report a tag that
# carries the object that was actually fetched, so a branch whose name happens
# to match a tag cannot make this stage pin a commit it did not build. `|| true`
# because "this ref is not a tag" is an answer and not a failure, and it is the
# normal one on the smoke line, which builds a branch.
tag=$(git -C qmdmm-src describe --exact-match --tags FETCH_HEAD 2>/dev/null || true)
if [ -n "$tag" ]; then
  url="$web/archive/refs/tags/$tag.tar.gz"
  stated=''
  source_line="tag $tag (commit $sha), version $version"
else
  url="$web/archive/$sha.tar.gz"
  stated="$version"
  source_line="$QMDMM_REF (commit $sha), version $version"
fi
sha256=$(curl -fsSL "$url" | shasum -a 256 | awk '{print $1}')
echo "source: $source_line"
echo "url:    $url"
echo "sha256: $sha256"

# Only the three lines the pin lives on are rewritten, and the commentary above
# them is deliberately left alone - a `url` or `sha256` mentioned in a comment
# is not on one of these lines.
awk -v url="$url" -v sha="$sha256" -v stated="$stated" '
  /^  url /     { print "  url \"" url "\""; next }
  /^  sha256 /  { print "  sha256 \"" sha "\""
                  if (stated != "") print "  version \"" stated "\""
                  next }
  /^  version / { next }
                { print }
' "$formula" > "$formula.pin"
mv "$formula.pin" "$formula"
ruby -c "$formula"

{
  echo '### The source pin this run packages'
  echo
  echo "The committed formula points at a released tag. This run packages"
  echo "\`$QMDMM_REF\`, so \`url\`, \`sha256\` and (when it had to) \`version\`"
  echo 'were re-derived before the build:'
  echo
  echo '```'
  grep -E '^  (url|sha256|version) ' "$formula"
  echo '```'
} >> "$GITHUB_STEP_SUMMARY"

# --build-bottle is not optional: `brew bottle` refuses a formula that was not
# installed this way, because the tab is where it reads `built_as_bottle` from.
# It also means Qt arrives here the way it arrives for a user - through the
# formula's own dependency - which is the half of "the declared dependencies
# are complete" that a build can check.
brew install --build-bottle "$HOMEBREW_TAP/qmdmm"

# The bottle's URL is built from this root when it is poured, and later stages
# have no way to reach this machine, so the value is a convention between the
# stages rather than something this one could discover: each consuming stage
# serves its own copy of the bottle directory at that address. Nothing is
# published from here - that is the release step's job, and it is not this
# workflow's.
# `--no-rebuild` is not a formality, and it is the only flag here that is doing
# something rather than stating something. Homebrew numbers a bottle by reading
# the tap's `origin/HEAD` formula and, *when it carries the same version as the
# one being bottled*, writing that formula's number plus one. That is this
# stage's case by construction: it clones the tap, which pins the tag being
# released. The number goes in as a dotted `.1` beside the word `bottle`, and
# this project's versions are semver, where a trailing `.1` reads as part of the
# version rather than as "the second build of the same one" - so it is not
# published. It buys nothing here either: the site and the formula are replaced
# whole on every publish, so one bottle name is never asked to mean two things.
#
# The flag is upstream's own - `rebuild ||= if args.no_rebuild? || !tap … 0` in
# `dev-cmd/bottle.rb`, ahead of the branch that derives the number, so it is not
# a matter of the formula's block happening to carry one. Its help text is
# narrower than its behaviour and reads as though it only edits the block.
# The log says which way it went: with the flag, the
# `Determining … bottle rebuild...` line never appears. (This machine cannot
# re-run it locally to prove that - `/opt/homebrew` belongs to another account -
# so the run log is where the reading comes from, and the guards below turn the
# opposite outcome into a named failure rather than a strange filename.)
brew bottle --json --no-rebuild --root-url "$BOTTLE_ROOT_URL" "$HOMEBREW_TAP/qmdmm"
ls -l ./*.bottle.*

mkdir -p out/bottles
# Matched by the widest shape `brew bottle` can write - `…bottle.tar.gz` and
# `…bottle.<rebuild>.tar.gz` - and not by the shape this run expects, so that a
# bottle carrying a rebuild segment is caught here and named. Written the narrow
# way, the glob stays literal and the stage dies on
# `cp: ./*.bottle.tar.gz: No such file or directory`, which says nothing about
# the `.1` on the end of the file that is sitting right there. The first
# dispatched run reported exactly that line. (`set --` costs nothing: this
# script takes no arguments.)
set -- ./[!_]*.bottle*.tar.gz
if [ ! -e "$1" ]; then
  echo "::error::brew bottle wrote no bottle archive in $(pwd). The .json is there, so the pin and the build both happened; what is missing is the file every later stage pours."
  exit 1
fi
if [ "$#" -ne 1 ]; then
  echo "::error::expected one bottle from this row, found $#: $*"
  exit 1
fi
case "$1" in
  ./*.bottle.*.tar.gz)
    echo "::error::the bottle carries a rebuild segment ($1). Versions here are semver, where a dotted suffix reads as part of the version, so a bottle so named is not published - see --no-rebuild above. If Homebrew numbered one anyway, that flag has stopped doing what it says."
    exit 1
    ;;
esac
# The file `brew bottle` writes has two hyphens between the name and the
# version; the name a bottle's URL carries has one. A run that shipped the
# first spelling as the second would 404 on the pour, and the failure would
# read as "no bottle for this tag" rather than as a typo.
poured=${1#./}
poured=${poured/--/-}

# The row's tag has to be in the *name*, because that name is the URL Homebrew
# builds and the tag is why this row exists at all. Checked before anything is
# collected: a bottle whose name does not carry the row's tag is a bottle that
# belongs to another row, and the merge stage would find its set incomplete.
case "$poured" in
  "qmdmm-$version.$MACOS_TAG.bottle.tar.gz") ;;
  *)
    echo "::error::this row declares $MACOS_TAG but produced '$poured', which is not qmdmm-$version.$MACOS_TAG.bottle.tar.gz. A bottle is fetched by the name its tag makes, so a row that produced another row's name is a row whose bottle nobody would fetch."
    exit 1
    ;;
esac

# The JSON is what the merge stage reads, and the block it writes comes out of
# it rather than out of the .tar.gz, so the two have to be about the same bytes.
# Homebrew wrote both in one command and this is the reading that says so: the
# checksum in the JSON is compared against the checksum of the file beside it.
#
# Found by a glob rather than by name, because the two names differ: the JSON
# sits beside the file Homebrew wrote, which spells the name with two hyphens
# where the URL spells it with one. Composing the JSON's name from the poured
# name would look for a file that is not there and report a brew bug.
# The count is taken over names that exist, not over the array: an unmatched
# glob stays literal, so `(./[!_]*.bottle*.json)` has length 1 when there is no
# JSON at all - the pattern itself - and a length test would pass. The stage
# would then reach python3 with a path that is not there and die on its
# traceback, which says nothing about which file is missing, and the count in
# the message would read 1 when the answer is 0.
n_json=$(ls -1 ./*.bottle*.json 2>/dev/null | grep -c . || true)
if [ "$n_json" -ne 1 ]; then
  echo "::error::expected one bottle JSON beside the bottle, found $n_json. The merge stage reads this file and nothing else for this row's checksum. What is here: $(ls -A . | tr '\n' ' ')"
  exit 1
fi
json=$(ls -1 ./*.bottle*.json)
json_sha=$(python3 -c '
import json, sys
p = sys.argv[1]
d = json.load(open(p))
for formula in d.values():
    for tag, t in (formula.get("bottle") or {}).get("tags", {}).items():
        print(tag, t["sha256"])
' "$json")
if [ "$json_sha" != "$MACOS_TAG $(shasum -a 256 "$1" | awk '{print $1}')" ]; then
  echo "::error::the JSON and the bottle disagree about what was built. JSON says '$json_sha'; the file hashes to '$MACOS_TAG $(shasum -a 256 "$1" | awk '{print $1}')'. The merge stage writes the block from the JSON, so a block built from these two would name a checksum no download could match."
  exit 1
fi

cp "$1" "out/bottles/$poured"
cp "$json" "out/bottles/${poured%.tar.gz}.json"
# The pinned formula travels with the row - not for its block, which is the
# merge stage's to write, but as the reading that all rows pinned the same
# source. merge-brew.sh compares the three byte for byte; three rows that
# disagree about the url, the sha256 or the version would be three bottles of
# three different things wearing one version number.
cp "$formula" out/qmdmm.pinned.rb

printf 'package\tversion\ttag\tfile\n' > out/MANIFEST.tsv
printf 'qmdmm\t%s\t%s\t%s\n' "$version" "$MACOS_TAG" "$poured" >> out/MANIFEST.tsv
# A header with no row under it is a manifest the merge stage reads as "this row
# built nothing", and it would then be merged as a two-row block. Both are
# silent; this is not.
if [ "$(awk 'NR > 1 { n++ } END { print n + 0 }' out/MANIFEST.tsv)" -ne 1 ]; then
  echo "::error::the manifest lists no bottle for this row. out/bottles holds: $(ls -A out/bottles 2>&1)"
  exit 1
fi

{
  echo "### The bottle this row produced"
  echo
  echo '```'
  cat out/MANIFEST.tsv
  echo '```'
  echo
  echo "Tag \`$MACOS_TAG\` is this runner's own macOS version, which is the"
  echo 'compatibility floor: a macOS older than this one cannot pour it, and a'
  echo 'newer one pours it only because the block lists it as the newest'
  echo 'compatible below that system. That is why the workflow runs one row per'
  echo 'supported macOS, and why the block the merge stage assembles has to'
  echo 'carry every row.'
  echo
  echo 'This row writes no block of its own; the formula it carries still has'
  echo 'whatever the tap ships, and merge-brew.sh replaces it with one that'
  echo 'lists every row of this run.'
} >> "$GITHUB_STEP_SUMMARY"
