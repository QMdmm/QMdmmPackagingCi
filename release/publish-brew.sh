#!/usr/bin/env bash
#
# Publish the Homebrew line's two products: the bottles, into the site, at the
# address the formula will name; and the formula itself, with that address
# written into it.
#
# The two halves are one step because they are one claim. A formula whose
# `root_url` names a directory a bottle is not in pours nothing - it falls back
# to building from source, with a warning, and every stage that ran would
# still have been green. So the URL is not composed twice and hoped over: each
# bottle is staged at the path the URL is made of, and the files' own presence
# is what the URL is checked against.
#
# A release carries one bottle per macOS version, so this stage works from the
# manifest rather than from a single name. It stages every row the manifest
# lists and refuses a directory that holds anything else, because the block in
# the formula names exactly the bottles this run produced: a bottle left behind
# by an earlier release would be served under an address nothing points at, and
# a bottle the manifest names but the artifact does not hold would be an
# address that 404s for one macOS and not for the others - the one shape of
# failure a pour reports as "no bottle for this tag" rather than as an error.
#
# Why an address on the site rather than a release asset: this is the same
# publication the other twelve lines go through - one address, served by the
# same branch, documented in one place - and it needs no credential beyond the
# `GITHUB_TOKEN` the publish job already holds, because the site belongs to the
# repository the job runs in. A bottle is at most a few hundred kilobytes, so
# what a release page would buy (a big-file host) is not what this needs.
#
# What a bottle published here is NOT: an archive. The site is the live
# repository, and the publish job rebuilds it from this run's artifacts, so the
# previous release's bottles are gone the moment this one is served. A user
# pouring the formula for the version the tap currently carries never looks at
# them; a user holding an older checkout of the tap would fall back to a source
# build, which is what they had before this line existed. That is the same
# bargain the apt and rpm lines already make, stated here because a bottle URL
# is the first thing in this repository whose absence reads as a warning rather
# than as an error.
#
# usage: publish-brew.sh <merged artifact dir> <assembled site dir>
# env:   PAGES
set -euo pipefail

# Both arguments are resolved against the directory the caller was in, and only
# then does this script move to the repository root. The other order is the one
# that looks harmless and is not: a relative path would start meaning something
# relative to here, which is how a run publishes the wrong tree and reports
# success about it.
PKGS_ARG="${1:?usage: publish-brew.sh <merged artifact dir> <site dir>}"
SITE_ARG="${2:?usage: publish-brew.sh <merged artifact dir> <site dir>}"
[ -d "$PKGS_ARG" ] || { echo "::error::$PKGS_ARG is not a directory; was merge-brew's artifact downloaded?"; exit 1; }
[ -d "$SITE_ARG" ] || { echo "::error::$SITE_ARG is not a directory; the site is assembled before this runs"; exit 1; }
PKGS="$(cd "$PKGS_ARG" && pwd)"
SITE="$(cd "$SITE_ARG" && pwd)"

cd "$(dirname "$0")/.."

PAGES="${PAGES:?}"
case "$PAGES" in
  */) echo "::error::PAGES ends with a slash, which would put a '//' in the bottles' URLs"; exit 1 ;;
esac
ROOT_URL="$PAGES/brew"

# The manifest rather than a glob for the version: merge-brew.sh writes it from
# the rows' own source trees' VERSION, which is the number the bottles' names
# already carry, and reading it is what lets the two be compared instead of one
# being derived from the other.
manifest="$PKGS/MANIFEST.tsv"
[ -f "$manifest" ] || { echo "::error::$manifest is missing"; exit 1; }
head -1 "$manifest" | grep -qE '^package\tversion\ttag\tfile$' || {
  echo "::error::$manifest does not begin with package/version/tag/file, so this is not the manifest merge-brew.sh writes; the columns below would be read as the wrong thing:"; cat "$manifest"; exit 1; }
version=$(awk -F'\t' 'NR>1 && $1=="qmdmm" {print $2}' "$manifest" | sort -u)
n_tags=$(awk -F'\t' 'NR>1 && $1=="qmdmm"' "$manifest" | wc -l | tr -d ' ')
[ "$n_tags" -ge 1 ] || { echo "::error::no qmdmm row in $manifest; it holds:"; cat "$manifest"; exit 1; }
if [ "$(printf '%s\n' "$version" | grep -c .)" -ne 1 ]; then
  echo "::error::$manifest names more than one version ($(printf '%s' "$version" | tr '\n' ' ')). The block names one version for every tag, and a site carrying bottles of two versions under one formula is a bottle nobody fetches."; exit 1
fi

formula="$PKGS/qmdmm.rb"
[ -f "$formula" ] || { echo "::error::$formula is missing; merge-brew.sh carries the formula with the block written in"; exit 1; }

# Every row: the name declared, or a named refusal. The name is part of the URL
# Homebrew builds, so a bottle called anything else is a bottle nobody fetches
# and the pour would report it as "no bottle for this tag".
declare -a staged=()
while IFS=$'\t' read -r pkg ver tag file; do
  [ "$pkg" = qmdmm ] || continue
  case "$file" in
    "qmdmm-$ver.$tag.bottle.tar.gz") ;;
    *) echo "::error::the manifest names '$file' for tag $tag, which is not qmdmm-$ver.$tag.bottle.tar.gz - the name is part of the URL Homebrew builds. A '.N' before the .tar.gz would be Homebrew's rebuild number, which this project does not publish: versions here are semver, where a dotted suffix reads as part of the version."; exit 1 ;;
  esac
  [ -f "$PKGS/bottles/$file" ] || { echo "::error::$PKGS/bottles/$file is missing, and the manifest names it"; ls -l "$PKGS" "$PKGS/bottles" 2>&1; exit 1; }
  staged+=("$file")
done < <(awk -F'\t' 'NR>1' "$manifest")
if [ "${#staged[@]}" -ne "$n_tags" ]; then
  echo "::error::the manifest lists $n_tags row(s) but only ${#staged[@]} of them are qmdmm rows"; cat "$manifest"; exit 1
fi
if [ "$(printf '%s\n' "${staged[@]}" | sort -u | grep -c .)" -ne "${#staged[@]}" ]; then
  echo "::error::the manifest names the same bottle twice: $(printf '%s ' "${staged[@]}")"; exit 1
fi

# The set the artifact holds, against the set the manifest names - so a bottle
# the merge published but the manifest lost, or a bottle left in the artifact by
# something else, is named here rather than served.
ls -1 "$PKGS/bottles" | grep -E '\.bottle\.tar\.gz$' | sort > /tmp/brew-on-disk.txt
printf '%s\n' "${staged[@]}" | sort > /tmp/brew-in-manifest.txt
if ! diff -u /tmp/brew-in-manifest.txt /tmp/brew-on-disk.txt > /tmp/brew-set.diff; then
  echo "::error::the bottles in the artifact and the bottles the manifest names are not the same set:"
  sed -e 's/^/  set| /' /tmp/brew-set.diff
  exit 1
fi

# One root_url line, and the block around it left exactly as the merge wrote it.
# `sed` counting rather than a grep for the same string: the point is that there
# is one line to rewrite, and a second one appearing (a future block carrying a
# mirror, say) would otherwise be rewritten in one place and left in the other.
n=$(grep -cE '^[[:space:]]*root_url[[:space:]]' "$formula" || true)
[ "$n" = 1 ] || { echo "::error::$formula has $n root_url lines, expected exactly 1"; sed -n '/bottle do/,/end/p' "$formula"; exit 1; }

# And the block's own count, read here as well as in the merge stage: this is
# the last point at which the number of bottles and the number of checksums can
# be compared before they are public, and the two are written by different
# stages.
n_block=$(sed -n '/^[[:space:]]*bottle do/,/^[[:space:]]*end/p' "$formula" \
  | grep -cE '^[[:space:]]*sha256[[:space:]]+cellar:' || true)
[ "$n_block" = "${#staged[@]}" ] || {
  echo "::error::the formula's block carries $n_block checksum line(s) and the manifest names ${#staged[@]} bottle(s). Publishing these together would leave a macOS version either without a bottle or without a line pointing at one."
  sed -n '/^[[:space:]]*bottle do/,/^[[:space:]]*end/p' "$formula"; exit 1; }

rewritten="$PKGS/qmdmm.rb.published"
sed -E "s|^([[:space:]]*)root_url[[:space:]]+\".*\"[[:space:]]*\$|\1root_url \"$ROOT_URL\"|" "$formula" > "$rewritten"

# What this rewrite is allowed to have done, as a reading rather than as a
# promise: exactly one line changed, it was the root_url, and its new value is
# the address the bottles below are being staged at. Anything else - a second
# changed line, a changed checksum, a changed url - is a rewrite that reached
# further than it said it would, and the formula published to the tap would then
# differ from the one every stage verified in a way nobody chose.
# `diff -u` exits 1 when the files differ, which is the one thing it is here to
# report, and an assignment takes its command substitution's status: under
# `set -e` the pipeline would therefore end the script on the very case it is
# measuring, silently and before the comparison. Hence `|| true` inside the
# substitution - and it has to wrap `diff`, not the assignment, because
# `pipefail` makes the pipeline's status the last non-zero one it saw.
diff_lines=$({ diff -u "$formula" "$rewritten" || true; } | tail -n +3)
changed=$(printf '%s\n' "$diff_lines" | grep -cE '^[-+]' || true)
if [ "$changed" != 2 ]; then
  echo "::error::rewriting root_url changed $changed lines, expected 2 (the old line and the new one):"
  printf '%s\n' "$diff_lines" | sed -e 's/^/  diff| /'
  exit 1
fi
if ! printf '%s\n' "$diff_lines" | grep -qE '^-([[:space:]]*)root_url'; then
  echo "::error::the changed line is not root_url:"; printf '%s\n' "$diff_lines" | sed -e 's/^/  diff| /'; exit 1
fi
if ! grep -qE "^([[:space:]]*)root_url \"$ROOT_URL\"\$" "$rewritten"; then
  echo "::error::the new root_url is not $ROOT_URL in $rewritten"; exit 1
fi
# The checksum lines are the ones whose silent alteration would turn a published
# bottle into a rejected download, and the check above would not notice a
# *changed* sha256 - it would only notice an extra changed line.
cmp -s <(grep -E '^[[:space:]]*sha256[[:space:]]' "$formula") \
       <(grep -E '^[[:space:]]*sha256[[:space:]]' "$rewritten") || {
  echo "::error::the bottle block's checksum lines are not byte-identical after the rewrite"; exit 1; }

# Stage, then read the staged paths back. The URLs below are not printed as
# promises: they are composed from where the files were just found.
rm -rf "$SITE/brew"
mkdir -p "$SITE/brew"
for file in "${staged[@]}"; do
  cp "$PKGS/bottles/$file" "$SITE/brew/$file"
  [ -f "$SITE/brew/$file" ] || { echo "::error::the bottle is not at $SITE/brew/$file after staging"; exit 1; }
done
cp "$rewritten" "$SITE/brew/qmdmm.rb"

printf 'package\tversion\ttag\turl\n' > "$PKGS/MANIFEST-published.tsv"
while IFS=$'\t' read -r pkg ver tag file; do
  [ "$pkg" = qmdmm ] || continue
  printf 'qmdmm\t%s\t%s\t%s/%s\n' "$ver" "$tag" "$ROOT_URL" "$file" >> "$PKGS/MANIFEST-published.tsv"
done < <(awk -F'\t' 'NR>1' "$manifest")
cat "$PKGS/MANIFEST-published.tsv"

{
  echo '### The bottles, as published'
  echo
  echo '```'
  cat "$PKGS/MANIFEST-published.tsv"
  echo '```'
  echo
  echo "Staged in \`brew/\`, with \`root_url \"$ROOT_URL\"\` written into"
  echo 'the formula beside them. The formula that goes into the tap is'
  echo "\`brew/qmdmm.rb\` on the site - this run's copy, not a second one - so"
  echo 'the tap learns about a bottle at the moment a release is cut and not'
  echo 'before.'
  echo
  echo 'The block as it will be poured from:'
  echo
  echo '```ruby'
  sed -n '/^[[:space:]]*bottle do/,/^[[:space:]]*end/p' "$rewritten"
  echo '```'
  echo
  echo "Nothing has fetched these bottles from \`$ROOT_URL\` yet: the site is"
  echo 'pushed after this step. What proves they are reachable is the trust'
  echo 'stage, which installs from the tap a user installs from and insists on'
  echo 'a pour - on the macOS the tap is installed on.'
} >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
