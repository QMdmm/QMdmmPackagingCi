#!/usr/bin/env bash
#
# Resolve the requested QMdmm ref once, for the whole run.
#
# Why this is a stage of its own: every job that fetches the source used to hand
# `$QMDMM_REF` straight to `git fetch --depth 1`, and each of those fetches
# resolves at the moment that job starts. Jobs start when a runner is free, not
# when the run does, and the macOS arm64 queue has held rows for the better part
# of a day (2026-10-26: 13h53m). So a branch name was a different commit for the
# late rows than for the early ones: stage A packaged a bottle from one tree and
# stage C compiled a later `main` against it, which surfaced as
# `no member named ...` in the sources - a red that reads as a code defect and
# is not one.
#
# Two shapes are already answers and are passed through unchanged:
#
#   * a full 40-character object name cannot move;
#   * a tag name cannot move either, and stage A re-derives the formula's pin
#     from the tag *by name* (`git describe --exact-match` in ci/pack-brew.sh),
#     so replacing it with a sha would change the recipe that line produces.
#
# Everything else names a ref that moves, and is written down here as the commit
# it points at right now. The stages then fetch that commit, so a run has one
# tree regardless of how long its rows wait.
#
# Input (environment):
#   QMDMM_REPO     - the repository to resolve in.
#   REQUESTED_REF  - what the run asked for: branch, tag, or full SHA.
# Output (through $GITHUB_OUTPUT):
#   ref            - what every stage should fetch.
set -euo pipefail

: "${QMDMM_REPO:?QMDMM_REPO is not set}"
: "${REQUESTED_REF:?REQUESTED_REF is not set}"
: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is not set}"

if [[ $REQUESTED_REF =~ ^[0-9a-f]{40}$ ]]; then
  echo "ref=$REQUESTED_REF" >> "$GITHUB_OUTPUT"
  echo "'$REQUESTED_REF' is a full object name: one commit, and it cannot move"
  exit 0
fi

# One listing answers every question below, and it is the only network call this
# stage makes. `ls-remote` writes "<object>\t<ref>", which is what the quoting
# below is about: a tab, so that a ref name is matched whole and not as a prefix
# of a longer one.
refs=$(git ls-remote "$QMDMM_REPO")

ref_exists() {
  awk -F'\t' -v wanted="$1" '$2 == wanted { found = 1 } END { exit !found }' <<<"$refs"
}

if ref_exists "refs/tags/$REQUESTED_REF"; then
  echo "ref=$REQUESTED_REF" >> "$GITHUB_OUTPUT"
  echo "'$REQUESTED_REF' is a tag: it does not move, and stage A reads the pin off it by name"
  exit 0
fi

sha=$(awk -F'\t' -v wanted="refs/heads/$REQUESTED_REF" '$2 == wanted { print $1; exit }' <<<"$refs")

# Not a branch and not a tag: a full ref as written (refs/pull/<n>/head, for
# one) is still a name a fetch can take, and it is the last thing to try.
if [ -z "$sha" ] && ref_exists "$REQUESTED_REF"; then
  sha=$(awk -F'\t' -v wanted="$REQUESTED_REF" '$2 == wanted { print $1; exit }' <<<"$refs")
fi

if [ -z "$sha" ]; then
  # The same failure an early fetch would have produced, said here instead: it
  # names the input, which is the thing that has to change.
  echo "::error::no ref named '$REQUESTED_REF' in $QMDMM_REPO"
  exit 1
fi

echo "ref=$sha" >> "$GITHUB_OUTPUT"
echo "'$REQUESTED_REF' is at $sha; every stage of this run fetches that commit"
