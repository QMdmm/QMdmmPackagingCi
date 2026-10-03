#!/usr/bin/env bash
#
# Publish the Homebrew line's two products: the bottle, into the site, at the
# address the formula will name; and the formula itself, with that address
# written into it.
#
# The two halves are one step because they are one claim. A formula whose
# `root_url` names a directory the bottle is not in pours nothing - it falls
# back to building from source, with a warning, and every stage that ran would
# still have been green. So the URL is not composed twice and hoped over: the
# bottle is staged at the path the URL is made of, and the file's own presence
# is what the URL is checked against.
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
# previous release's bottle is gone the moment this one is served. A user
# pouring the formula for the version the tap currently carries never looks at
# it; a user holding an older checkout of the tap would fall back to a source
# build, which is what they had before this line existed. That is the same
# bargain the apt and rpm lines already make, stated here because a bottle URL
# is the first thing in this repository whose absence reads as a warning rather
# than as an error.
#
# usage: publish-brew.sh <pack-brew artifact dir> <assembled site dir>
# env:   PAGES
set -euo pipefail

# Both arguments are resolved against the directory the caller was in, and only
# then does this script move to the repository root. The other order is the one
# that looks harmless and is not: a relative path would start meaning something
# relative to here, which is how a run publishes the wrong tree and reports
# success about it.
PKGS_ARG="${1:?usage: publish-brew.sh <pack-brew artifact dir> <site dir>}"
SITE_ARG="${2:?usage: publish-brew.sh <pack-brew artifact dir> <site dir>}"
[ -d "$PKGS_ARG" ] || { echo "::error::$PKGS_ARG is not a directory; was pack-brew's artifact downloaded?"; exit 1; }
[ -d "$SITE_ARG" ] || { echo "::error::$SITE_ARG is not a directory; the site is assembled before this runs"; exit 1; }
PKGS="$(cd "$PKGS_ARG" && pwd)"
SITE="$(cd "$SITE_ARG" && pwd)"

cd "$(dirname "$0")/.."

PAGES="${PAGES:?}"
case "$PAGES" in
  */) echo "::error::PAGES ends with a slash, which would put a '//' in the bottle's URL"; exit 1 ;;
esac
ROOT_URL="$PAGES/brew"

# The manifest rather than a glob for the version: pack-brew.sh writes it from
# the source tree's own VERSION, which is the number the artifact's name already
# carries, and reading it is what lets the two be compared instead of one being
# derived from the other.
manifest="$PKGS/MANIFEST.tsv"
[ -f "$manifest" ] || { echo "::error::$manifest is missing"; exit 1; }
version=$(awk -F'\t' 'NR>1 && $1=="qmdmm" {print $2}' "$manifest")
bottle=$(awk -F'\t' 'NR>1 && $1=="qmdmm" {print $3}' "$manifest")
[ -n "$version" ] && [ -n "$bottle" ] || {
  echo "::error::no qmdmm row in $manifest; it holds:"; cat "$manifest"; exit 1; }
[ -f "$PKGS/bottles/$bottle" ] || { echo "::error::$PKGS/bottles/$bottle is missing"; ls -l "$PKGS" "$PKGS/bottles" 2>&1; exit 1; }

formula="$PKGS/qmdmm.rb"
[ -f "$formula" ] || { echo "::error::$formula is missing; stage A carries the formula with the block written in"; exit 1; }

# The name the formula's block is keyed on, asserted rather than trusted. A
# bottle under a name Homebrew will not derive from the formula is a bottle
# nobody fetches, and the pour would report it as "no bottle for this tag".
case "$bottle" in
  "qmdmm-$version".*.bottle.tar.gz) ;;
  *) echo "::error::the bottle is named '$bottle', which is not qmdmm-$version.<tag>.bottle.tar.gz - the name is part of the URL Homebrew builds. A '.N' before the .tar.gz would be Homebrew's rebuild number, which this project does not publish: versions here are semver, where a dotted suffix reads as part of the version."; exit 1 ;;
esac
tag=$(printf '%s' "$bottle" | sed -E "s/^qmdmm-$version\.(.*)\.bottle\.tar\.gz$/\1/")

# One root_url line, and the block around it left exactly as stage A wrote it.
# `sed` counting rather than a grep for the same string: the point is that there
# is one line to rewrite, and a second one appearing (a future block carrying a
# mirror, say) would otherwise be rewritten in one place and left in the other.
n=$(grep -cE '^[[:space:]]*root_url[[:space:]]' "$formula" || true)
[ "$n" = 1 ] || { echo "::error::$formula has $n root_url lines, expected exactly 1"; sed -n '/bottle do/,/end/p' "$formula"; exit 1; }

rewritten="$PKGS/qmdmm.rb.published"
sed -E "s|^([[:space:]]*)root_url[[:space:]]+\".*\"[[:space:]]*\$|\1root_url \"$ROOT_URL\"|" "$formula" > "$rewritten"

# What this rewrite is allowed to have done, as a reading rather than as a
# promise: exactly one line changed, it was the root_url, and its new value is
# the address the bottle below is being staged at. Anything else - a second
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
# The checksum line is the one thing whose silent alteration would turn a
# published bottle into a rejected download, and the check above would not
# notice a *changed* sha256 - it would only notice an extra changed line.
cmp -s <(grep -E '^[[:space:]]*sha256[[:space:]]' "$formula") \
       <(grep -E '^[[:space:]]*sha256[[:space:]]' "$rewritten") || {
  echo "::error::the bottle block's checksum line is not byte-identical after the rewrite"; exit 1; }

# Stage, then read the staged path back. The URL below is not printed as a
# promise: it is composed from where the file was just found.
rm -rf "$SITE/brew"
mkdir -p "$SITE/brew"
cp "$PKGS/bottles/$bottle" "$SITE/brew/$bottle"
cp "$rewritten" "$SITE/brew/qmdmm.rb"
[ -f "$SITE/brew/$bottle" ] || { echo "::error::the bottle is not at $SITE/brew/$bottle after staging"; exit 1; }

printf 'package\tversion\ttag\turl\n' > "$PKGS/MANIFEST-published.tsv"
printf 'qmdmm\t%s\t%s\t%s/%s\n' "$version" "$tag" "$ROOT_URL" "$bottle" >> "$PKGS/MANIFEST-published.tsv"
cat "$PKGS/MANIFEST-published.tsv"

{
  echo '### The bottle, as published'
  echo
  echo '```'
  cat "$PKGS/MANIFEST-published.tsv"
  echo '```'
  echo
  echo "Staged at \`brew/$bottle\`, with \`root_url \"$ROOT_URL\"\` written"
  echo 'into the formula beside it. The formula that goes into the tap is'
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
  echo "Nothing has fetched \`$ROOT_URL/$bottle\` yet: the site is pushed"
  echo 'after this step. What proves it is reachable is the trust stage, which'
  echo 'installs from the tap a user installs from and insists on a pour.'
} >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
