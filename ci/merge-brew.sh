#!/usr/bin/env bash
#
# Assemble the Homebrew line's one bottle block out of every row's bottle.
#
# A bottle records one exact build on one exact macOS version, so a recipe that
# serves three macOS versions needs three bottles and a block with three
# checksums in it. No single row can write that block: the row that bottled on
# macOS 15 knows its own bottle and nothing about the other two. A row does write
# a block for the bottle it built - that is what makes the daily line's one-row
# formula complete, since there is no stage between A and the row that pours it -
# and on this line the rows each write one of those, which is the intermediate
# state this stage replaces. It is one job, on one machine, after all of them:
# it takes the JSONs the rows produced and turns them into the block, and the
# formula carrying it, that a user's `brew install` reads.
#
# `brew bottle --merge` is upstream's own answer to exactly this: it takes any
# number of `--json` files, merges them into one block, and writes the block
# into the formula the JSONs name. What this stage adds is the part upstream
# leaves to the caller, because in homebrew/core the bottles come from CI jobs
# whose exit statuses are trusted rather than read:
#
#   * the rows are asserted to be the set the workflow declared, one bottle
#     each, all pinned to the same source - three rows that disagree about the
#     pin would be three bottles of three different things wearing one version.
#     That comparison takes each row's own bottle block off both sides: a row
#     writes the block for the bottle it built, because on a one-row line that
#     block is the whole one and stage B installs the formula as it stands. So
#     the block is the one part of the file that is *meant* to differ between
#     rows, and "the same source" is the recipe without it;
#   * every checksum in the block is read back out and compared against the JSON
#     it came from, so the block is the rows' own content rather than whatever
#     the merge left behind;
#   * the block's *order* is asserted, and that one is not cosmetic: Homebrew
#     pours a bottle for the newest macOS version not newer than the machine
#     (`find_older_compatible_tag`, which walks the block in file order), so a
#     block that listed the oldest tag first would hand a macOS 27 user the
#     macOS 15 build. Homebrew's own writer sorts the block newest-first and
#     this stage is where that is a reading instead of an assumption.
#
# usage: merge-brew.sh <out dir> <row dir>...
# env:   MACOS_TAGS        the expected tags, in the order the block must list
#                          them (descending macOS version), space separated
#        HOMEBREW_TAP      the tap the formula lives in
#        BOTTLE_ROOT_URL   the address the bottles will be poured from
set -euo pipefail

: "${MACOS_TAGS:?the expected bottle tags, space separated, newest first}"
read -r -a expected <<<"$MACOS_TAGS"
HOMEBREW_TAP="${HOMEBREW_TAP:?}"
BOTTLE_ROOT_URL="${BOTTLE_ROOT_URL:?}"

out="${1:?usage: merge-brew.sh <out dir> <row dir>...}"
shift
if [ "$#" -lt 1 ]; then
  echo "::error::no row directory was given. Each argument is one pack-brew row's artifact; the workflow downloads them into one directory and passes them here."
  exit 1
fi
if [ "$#" -ne "${#expected[@]}" ]; then
  echo "::error::MACOS_TAGS lists ${#expected[@]} tag(s) (${MACOS_TAGS}) but $# row(s) were handed over. A row that failed to produce a bottle arrives here as a missing directory, and merging the rest would publish a block that says "no bottle for this macOS" without saying so."
  exit 1
fi

# --- the rows, as readings -------------------------------------------------
rows=()
version=''
for dir in "$@"; do
  manifest="$dir/MANIFEST.tsv"
  [ -f "$manifest" ] || { echo "::error::$dir carries no MANIFEST.tsv, so this row's artifact is not a stage A artifact (or stage A failed before writing one)"; exit 1; }
  n=$(awk 'NR > 1 && $1 == "qmdmm" { n++ } END { print n + 0 }' "$manifest")
  [ "$n" = 1 ] || { echo "::error::$manifest lists $n qmdmm row(s), expected exactly 1:"; cat "$manifest"; exit 1; }

  row_version=$(awk -F'\t' 'NR > 1 && $1 == "qmdmm" { print $2 }' "$manifest")
  tag=$(awk -F'\t' 'NR > 1 && $1 == "qmdmm" { print $3 }' "$manifest")
  file=$(awk -F'\t' 'NR > 1 && $1 == "qmdmm" { print $4 }' "$manifest")
  [ -n "$tag" ] && [ -n "$file" ] || { echo "::error::$manifest has no tag or no file in its row:"; cat "$manifest"; exit 1; }
  [ -f "$dir/bottles/$file" ] || { echo "::error::$dir/bottles/$file is missing, and the manifest names it"; ls -l "$dir/bottles" 2>&1; exit 1; }
  [ -f "$dir/qmdmm.rb" ] || { echo "::error::$dir carries no qmdmm.rb"; exit 1; }

  case " ${MACOS_TAGS} " in
    *" $tag "*) ;;
    *) echo "::error::row $dir reports tag '$tag', which is not one of the tags this run declared (${MACOS_TAGS})"; exit 1 ;;
  esac
  if [ -z "$version" ]; then version="$row_version"; fi
  [ "$row_version" = "$version" ] || { echo "::error::two rows disagree about the version: $version and $row_version. The block names one version for every tag, so a run whose rows built different versions cannot be published as one."; exit 1; }

  rows+=("$dir")
  echo "row $tag: $file ($row_version)"
done

# Every declared tag is present exactly once. The count check above makes a
# duplicate impossible only if no row is missing, and this is the reading that
# says the argument list is the whole set rather than three names for two rows.
for tag in "${expected[@]}"; do
  hits=$(printf '%s\n' "${rows[@]}" | while read -r d; do awk -F'\t' -v t="$tag" 'NR > 1 && $1 == "qmdmm" && $3 == t { print $3 }' "$d/MANIFEST.tsv"; done | grep -c . || true)
  [ "$hits" = 1 ] || { echo "::error::the row set carries $hits bottle(s) tagged $tag, expected exactly 1. Rows: ${rows[*]}"; exit 1; }
done

# The recipe with this row's bottle block taken off - the part of the file that
# is the run's own rather than the tap's. Everything below that asks "did the
# rows package the same thing" asks it about this, because the block is where
# they are *supposed* to differ: each row writes a block naming the bottle it
# built, and this stage is what turns those into one. The address range ends at
# the first `end` indented inside the block, which is the block's own - every
# other `end` in the file is at column zero.
strip_block() { sed -e '/^[[:space:]]*bottle do/,/^[[:space:]]*end$/d' "$1"; }

# The pin, byte for byte. The three rows derive it from the same ref with the
# same code, so anything but identical means one of them packaged something
# else - and the block below would then name checksums for bottles built from a
# different source than the recipe beside them.
first="${rows[0]}/qmdmm.rb"
for dir in "${rows[@]:1}"; do
  if ! diff -q <(strip_block "$first") <(strip_block "$dir/qmdmm.rb") >/dev/null; then
    echo "::error::$first and $dir/qmdmm.rb differ outside the bottle block, so the rows did not pin the same source. The block below names checksums for bottles of one thing; a recipe pinned to another would pour them against the wrong tree. Difference (each row's own block removed):"
    diff -u <(strip_block "$first") <(strip_block "$dir/qmdmm.rb") | tail -n +3 | sed -e 's/^/  pin| /'
    exit 1
  fi
done
echo "all $# rows pinned the same source, byte for byte apart from each row's own block"

# --- what the tap already ships --------------------------------------------
# A tap whose formula is not reachable here cannot be the formula this run
# merges into, and the JSONs resolve their formula by a path *relative to the
# Homebrew repository* - so this job's Homebrew has to be the same shape as the
# rows'. Both are arm64 macOS runners (every row is), which is why the merge job
# is not free to run on Intel: there the tap would sit under /usr/local and the
# path in the JSON would resolve to nothing.
brew tap "$HOMEBREW_TAP"
brew trust --tap "$HOMEBREW_TAP"
tap_dir=$(brew --repo "$HOMEBREW_TAP")
formula="$tap_dir/Formula/qmdmm.rb"
test -f "$formula"

# The recipe the tap ships, before this stage touches it. What this stage puts
# into it is the pin and the block, so a row's formula that differs anywhere else
# is a row that packaged a different recipe rather than a different ref. Both
# sides are read with the block taken off - the tap's is the previous release's
# and the row's is this run's own, and neither is what this comparison is about.
shipped=/tmp/qmdmm.shipped.rb
if git -C "$tap_dir" show origin/HEAD:Formula/qmdmm.rb > "$shipped" 2>/dev/null && [ -s "$shipped" ]; then
  changed=$(diff -u <(strip_block "$shipped") <(strip_block "$first") | tail -n +3 | grep -cE '^[-+]' || true)
  stray=$(diff -u <(strip_block "$shipped") <(strip_block "$first") | tail -n +3 | grep -E '^[-+]' | grep -vE '^[-+][[:space:]]*(url|sha256|version)[[:space:]]' | grep -c . || true)
  echo "the rows' pin differs from the tap's own formula in $changed line(s), $stray of them outside url/sha256/version (blocks on both sides removed)"
  if [ "$stray" != 0 ]; then
    echo "::error::the pinned formula differs from the recipe the tap ships outside the three pin lines, so the rows did not package the recipe a user gets:"
    diff -u <(strip_block "$shipped") <(strip_block "$first") | tail -n +3 | sed -e 's/^/  pin| /'
    exit 1
  fi
else
  echo "::warning::could not read origin/HEAD:Formula/qmdmm.rb from the tap checkout, so the tap's own recipe was not compared against the pin"
fi

# One row's formula goes in as the file the merge writes into. Not for its block,
# which names that row's bottle alone and is about to be replaced: because the
# merge needs the recipe and the pin in place, and this is the copy the rows
# built. `--write` replaces a block rather than adding to one, and the tap is the
# evidence - the formula it ships still carried the previous release's block when
# the last release ran, and came out of this same call with only the new one.
install -m 644 "$first" "$formula"
ruby -c "$formula"

# --- the merge -------------------------------------------------------------
# Sorted, so the log and any failure below are deterministic. The order of the
# arguments does not decide the block's order - `BottleSpecification#checksums`
# sorts that itself - but a stage whose behaviour depends on an argument order
# should not be handed one at random.
jsons=()
sorted=()
while IFS= read -r dir; do sorted+=("$dir"); done < <(printf '%s\n' "${rows[@]}" | sort)
for dir in "${sorted[@]}"; do
  j=("$dir"/bottles/*.json)
  if [ "${#j[@]}" -ne 1 ] || [ ! -f "${j[0]}" ]; then
    echo "::error::expected one bottle JSON in $dir/bottles, found ${#j[@]}: ${j[*]}"
    exit 1
  fi
  jsons+=("${j[0]}")
done

# `--no-commit`: the tap's git state is not this stage's business. The formula
# travels on as an artifact, and release/publish-tap.sh is the one place that
# commits to the tap, with its own bounded-diff rule about what it may change.
brew developer on
echo "merging ${#jsons[@]} bottle JSON(s): ${jsons[*]}"
brew bottle --merge --write --no-commit "${jsons[@]}"

# --- read the block back ---------------------------------------------------
block=$(sed -n '/^[[:space:]]*bottle do/,/^[[:space:]]*end/p' "$formula")
[ -n "$block" ] || { echo "::error::no bottle block in $formula after the merge, so nothing was written"; exit 1; }

n_root=$(printf '%s\n' "$block" | grep -cE '^[[:space:]]*root_url[[:space:]]' || true)
[ "$n_root" = 1 ] || { echo "::error::the block has $n_root root_url line(s), expected 1:"; printf '%s\n' "$block"; exit 1; }
printf '%s\n' "$block" | grep -qE "^[[:space:]]*root_url \"$BOTTLE_ROOT_URL\"\$" || {
  echo "::error::the block's root_url is not $BOTTLE_ROOT_URL, which is the address every consuming stage serves the bottles at:"
  printf '%s\n' "$block" | sed -e 's/^/  block| /'; exit 1; }

got_tags=$(printf '%s\n' "$block" | sed -nE 's/^[[:space:]]*sha256[[:space:]]+cellar: [^,]*, ([a-z0-9_]+):.*/\1/p')
n_tags=$(printf '%s\n' "$got_tags" | grep -c . || true)
[ "$n_tags" = "${#expected[@]}" ] || {
  echo "::error::the block carries $n_tags bottle tag(s), expected ${#expected[@]} (${MACOS_TAGS}):"
  printf '%s\n' "$block" | sed -e 's/^/  block| /'; exit 1; }

# The set and the order in one comparison. Descending macOS version is not
# decoration: Homebrew walks the block in file order when it looks for a bottle
# for a macOS newer than every tag, so the first line has to be the newest.
[ "$(printf '%s' "$got_tags" | tr '\n' ' ' | sed -e 's/ $//')" = "$MACOS_TAGS" ] || {
  echo "::error::the block lists its tags as '$(printf '%s' "$got_tags" | tr '\n' ' ' | sed -e 's/ $//')', and this run declared '$MACOS_TAGS'. The order is behaviour rather than formatting - Homebrew pours the first tag for a macOS that is not newer than the machine - and the set has to be every row."
  printf '%s\n' "$block" | sed -e 's/^/  block| /'; exit 1; }

# The digests, against the JSONs they came from. A block whose lines are
# well-formed but whose numbers came from somewhere else would pour nothing and
# would report it as "no bottle for this tag", which is the failure mode every
# stage after this one is written to notice only if the number is right.
for dir in "${rows[@]}"; do
  j=("$dir"/bottles/*.json)
  python3 - "${j[0]}" "$block" <<'PY' || exit 1
import json, re, sys
path, block = sys.argv[1], sys.argv[2]
doc = json.load(open(path))
want = {}
for formula in doc.values():
    for tag, t in (formula.get("bottle") or {}).get("tags", {}).items():
        want[tag] = t["sha256"]
have = dict(re.findall(r'sha256\s+cellar: [^,]*, ([a-z0-9_]+):\s+"([0-9a-f]{64})"', block))
bad = [f"{tag}: JSON {sha}, block {have.get(tag)}" for tag, sha in want.items() if have.get(tag) != sha]
if bad:
    print(f"::error::the block does not carry {path}'s checksum(s): " + "; ".join(bad))
    sys.exit(1)
print("block checksums match " + path)
PY
done

# --- the artifact ----------------------------------------------------------
version=$(awk -F'\t' 'NR > 1 && $1 == "qmdmm" { print $2; exit }' "${rows[0]}/MANIFEST.tsv")
mkdir -p "$out/bottles"
for dir in "${rows[@]}"; do
  file=$(awk -F'\t' 'NR > 1 && $1 == "qmdmm" { print $4 }' "$dir/MANIFEST.tsv")
  cp "$dir/bottles/$file" "$out/bottles/$file"
done
cp "$formula" "$out/qmdmm.rb"

printf 'package\tversion\ttag\tfile\n' > "$out/MANIFEST.tsv"
for dir in "${rows[@]}"; do
  awk -F'\t' -v OFS='\t' 'NR > 1 && $1 == "qmdmm" { print $1, $2, $3, $4 }' "$dir/MANIFEST.tsv" >> "$out/MANIFEST.tsv"
done
# One directory, three bottles, and every later stage reads this file rather
# than a glob: a stage that globbed would still work if a row's bottle were
# missing from the set, and would then pour the wrong one without saying so.
n_rows=$(awk 'NR > 1 { n++ } END { print n + 0 }' "$out/MANIFEST.tsv")
[ "$n_rows" = "${#expected[@]}" ] || {
  echo "::error::the published manifest lists $n_rows bottle(s), expected ${#expected[@]}"; cat "$out/MANIFEST.tsv"; exit 1; }
for tag in "${expected[@]}"; do
  f=$(awk -F'\t' -v t="$tag" 'NR > 1 && $1 == "qmdmm" && $3 == t { print $4 }' "$out/MANIFEST.tsv")
  [ -f "$out/bottles/$f" ] || { echo "::error::$out/bottles/$f is missing after the merge assembled the artifact"; exit 1; }
done

cat "$out/MANIFEST.tsv"
{
  echo '### The bottle block, assembled from every row'
  echo
  echo "Rows merged: ${#expected[@]} - \`$MACOS_TAGS\`."
  echo
  echo '```'
  cat "$out/MANIFEST.tsv"
  echo '```'
  echo
  echo 'The block as it will be poured from. One checksum per macOS version,'
  echo 'newest first: a macOS newer than every tag listed pours the first line,'
  echo 'so the order is what stands between a macOS 27 user and the macOS 15'
  echo 'build.'
  echo
  echo '```ruby'
  printf '%s\n' "$block"
  echo '```'
} >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
