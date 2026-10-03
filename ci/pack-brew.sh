#!/usr/bin/env bash
#
# Stage A for the Homebrew line, in one file: tap the repository that holds the
# formula, re-derive its source pin for the ref this run was given, install it
# from source with --build-bottle, bottle it, write the bottle block back into
# the tap's own copy of the formula, and collect the two things the later
# stages need - the bottle and that formula.
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
set -euxo pipefail

# `brew bottle` is a developer command, and Homebrew turns developer mode on by
# itself the first time one is called - once, with a warning, in the middle of
# this stage's log. Asking for it up front keeps that out of the way.
brew developer on

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
git -C qmdmm-src checkout --detach FETCH_HEAD
echo "QMdmm HEAD: $(git -C qmdmm-src log --oneline -1)"

sha=$(git -C qmdmm-src rev-parse FETCH_HEAD)
web=${QMDMM_REPO%.git}
version=$(awk '/^project\(/ { in_project = 1 } \
              in_project && /VERSION/ { \
                sub(/.*VERSION[ \t]+/, ""); sub(/[ \t].*/, ""); print; exit \
              }' qmdmm-src/CMakeLists.txt)
if [ -z "$version" ]; then
  echo "::error::no VERSION found in qmdmm-src/CMakeLists.txt"
  exit 1
fi

commented=''
if tag=$(git -C qmdmm-src describe --exact-match --tags FETCH_HEAD 2>/dev/null) && [ -n "$tag" ]; then
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
# so the run log is where the reading comes from, and the guard below turns the
# opposite outcome into a named failure rather than a strange filename.)
brew bottle --json --no-rebuild --root-url "$BOTTLE_ROOT_URL" "$HOMEBREW_TAP/qmdmm"
ls -l ./*.bottle.*

# Writing the block back into the tap's copy is what makes the *tap's* file the
# one carrying real checksums. --no-commit because the tap's git state is not
# this stage's business: the authenticated copy of the formula travels on as an
# artifact instead.
brew bottle --merge --write --no-commit ./*.bottle.json

if ! grep -q '^  bottle do' "$formula"; then
  echo "::error::the bottle block was not written into the tap's formula"
  exit 1
fi

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
  echo "::error::brew bottle wrote no bottle archive in $(pwd). The .json is there, so the block did reach the formula; what is missing is the file every later stage pours."
  exit 1
fi
if [ "$#" -ne 1 ]; then
  echo "::error::expected one bottle for a single-arch build, found $#: $*"
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
cp "$1" "out/bottles/$poured"
cp "$formula" out/qmdmm.rb

# Read back out of the bottle block rather than assumed: the tag is the
# producing runner's macOS version, which is the compatibility floor, and it is
# the one field here that must not be guessed at. `-E`, because the alternation
# a BRE would need (`\|`) is a GNU extension this platform's sed does not have.
#
# Mind the indentation: `bottle do` sits at two spaces but `root_url` / `sha256`
# are one level further in, so anchoring on the block's own indentation matches
# nothing - and an empty read is indistinguishable from "the block has no tag",
# which is what the first dispatched run reported while the tag sat right there.
tags=$(sed -nE 's/^[[:space:]]*sha256[[:space:]]+cellar: [^,]*, (arm64_[a-z0-9_]*|x86_64_[a-z0-9_]*|all):.*/\1/p' out/qmdmm.rb)
echo "bottle tags written into the formula: $tags"
case "$tags" in
  arm64_*) ;;
  *)
    echo "::error::no usable bottle tag in the formula's bottle block; this runner is $(uname -m) on $(sw_vers -productVersion). The block as written:"
    sed -n '/bottle do/,/end/p' out/qmdmm.rb
    exit 1
    ;;
esac
if [ "$(printf '%s\n' "$tags" | grep -c .)" -ne 1 ]; then
  echo "::error::expected exactly one bottle tag for a single-arch build, got: $tags"
  exit 1
fi

printf 'package\tversion\tfile\n' > out/MANIFEST.tsv
for f in out/bottles/*.bottle.tar.gz; do
  printf 'qmdmm\t%s\t%s\n' "$version" "$(basename "$f")" >> out/MANIFEST.tsv
done
# A header with no row under it is a manifest every later stage reads as "this
# run built nothing", and `publish-brew.sh` would go looking for a file that was
# never named. Both are silent; this is not.
if [ "$(awk 'NR > 1 { n++ } END { print n + 0 }' out/MANIFEST.tsv)" -ne 1 ]; then
  echo "::error::the manifest lists no bottle. out/bottles holds: $(ls -A out/bottles 2>&1)"
  exit 1
fi

{
  echo '### The bottle produced'
  echo
  echo '```'
  cat out/MANIFEST.tsv
  echo '```'
  echo
  echo "Tag \`$tags\` is the runner's own macOS version, which is the"
  echo 'compatibility floor: a macOS older than this one cannot pour it. That'
  echo 'is why a bottle line needs one runner per supported macOS, and why the'
  echo 'producing runner and the consuming runner have to be the same OS.'
  echo
  echo 'The formula as it will be poured, i.e. with the block written back:'
  echo
  echo '```ruby'
  sed -n '/^  bottle do/,/^  end/p' out/qmdmm.rb
  echo '```'
} >> "$GITHUB_STEP_SUMMARY"
