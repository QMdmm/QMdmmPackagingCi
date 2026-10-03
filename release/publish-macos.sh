#!/usr/bin/env bash
#
# Attach the macOS disk image to the release on the *product* repository.
#
# Why the two macOS faces publish to different places, which is the first thing
# to understand about this file. A bottle is an input to a recipe: what a
# consumer configures is the tap, and the bottle is fetched from wherever the
# formula says. A .dmg is not - it is the product itself, and the page a person
# looks at to download it is the product's own release page. So the bottle goes
# to the site (release/publish-brew.sh) and this goes to QMdmm/QMdmm.
#
# That is also why this is the one stage in release/ that needs a credential
# other than the GITHUB_TOKEN: the repository it writes to is not the repository
# the workflow runs in, and no token issued to a workflow can write outside it.
#
# The rule this stage was asked to keep, and keeps twice over.
#
# Adding an asset to an existing release is ADDITIVE. A release page is
# assembled by several runs - a rebuild of one product does not rebuild the
# others, and the products a later run adds are not the ones an earlier run
# left - so what is already there is somebody else's and is not this stage's to
# touch. That is asserted below rather than intended: the asset names are read
# before the upload and again after it, and the difference has to be exactly
# this run's file. An upload that dropped an asset, or that asked for a
# replacement, fails here even though `gh` would have said it succeeded.
#
# And of the asset this run does produce: one that is already there is never
# overwritten. Nothing here passes --clobber, and the check below is not the
# default's error message dressed up - it runs *before* the upload and compares
# what GitHub already holds against what this run built, so an asset that is
# there and different is a refusal that says why rather than a 422 that says
# "exists". Re-dispatching a release therefore cannot silently replace the .dmg
# somebody may already have downloaded; a person has to delete it on purpose.
# An asset that is there and *identical* is reported as already published and
# is not an error, because nothing is being overwritten in that case either.
#
# usage: publish-macos.sh <pack-macos artifact dir>
# env:   GH_TOKEN     (the product repository's token; absent is a hard failure)
#        QMDMM_REPO   (the clone URL; the owner/name is read out of it)
#        QMDMM_REF    (the tag the release carries)
set -euo pipefail

# Resolved against the caller's directory, before this script moves to the
# repository root: the other order would make a relative path mean something
# relative to here, which is how a run attaches an artifact out of nowhere and
# reports success about it.
PKGS_ARG="${1:?usage: publish-macos.sh <pack-macos artifact dir>}"
[ -d "$PKGS_ARG" ] || { echo "::error::$PKGS_ARG is not a directory; was pack-macos' artifact downloaded?"; exit 1; }
PKGS="$(cd "$PKGS_ARG" && pwd)"

cd "$(dirname "$0")/.."

# A missing token is a failure and not a skip. The alternative - a run that
# reports success having published nothing - is the one outcome this whole
# workflow is arranged to make impossible.
if [ -z "${GH_TOKEN:-}" ]; then
  echo "::error::GH_TOKEN is empty. It carries PRODUCT_RELEASE_TOKEN, a token for ${QMDMM_REPO:-the product repository} with contents:write; without it the disk image cannot be attached and this run has not published it."
  exit 1
fi
command -v gh >/dev/null || { echo "::error::gh is not installed in this image"; exit 1; }

# The owner/name is read out of the URL the rest of the workflow already uses
# rather than listed again: a second copy of it is a copy that can disagree.
slug="${QMDMM_REPO%.git}"
slug="${slug#https://github.com/}"
slug="${slug#git@github.com:}"
case "$slug" in
  */*) ;;
  *) echo "::error::cannot read an owner/name out of QMDMM_REPO='${QMDMM_REPO:-}'"; exit 1 ;;
esac
TAG="${QMDMM_REF:?QMDMM_REF (the tag) is not set}"
echo "release $TAG on $slug"

manifest="$PKGS/MANIFEST.tsv"
[ -f "$manifest" ] || { echo "::error::$manifest is missing"; exit 1; }
version=$(awk -F'\t' 'NR>1 && $1=="qmdmm" {print $2}' "$manifest")
dmg_name=$(awk -F'\t' 'NR>1 && $1=="qmdmm" {print $3}' "$manifest")
[ -n "$dmg_name" ] || { echo "::error::no qmdmm row in $manifest:"; cat "$manifest"; exit 1; }
dmg="$PKGS/$dmg_name"
[ -f "$dmg" ] || { echo "::error::$dmg is missing"; ls -l "$PKGS"; exit 1; }

# The artifact's own name carries the version, and both have to agree with each
# other and with the tag. Attaching a 0.0.2 image to the 0.0.1 release is not a
# mistake anything downstream would catch - the file would simply be there, with
# the wrong name for the page it is on. A tag that is not the bare version
# (`v0.0.1`, say) fails here deliberately: reconciling the two is then a
# decision somebody makes rather than something this script guesses at.
case "$dmg_name" in
  "QMdmm-$version-Darwin.dmg") ;;
  *) echo "::error::the image is named '$dmg_name', which is not QMdmm-$version-Darwin.dmg - the manifest's version and its file name disagree"; exit 1 ;;
esac
if [ "$version" != "$TAG" ]; then
  echo "::error::the artifact is version $version but the release is tag '$TAG'. The two are compared rather than one derived from the other, because a tag that is not the bare version has to be reconciled deliberately."
  exit 1
fi

size=$(wc -c < "$dmg" | tr -d ' ')
digest="sha256:$(shasum -a 256 "$dmg" | awk '{print $1}')"
echo "built: $dmg_name  $size bytes  $digest"

# The release has to be there already. Creating it is a person's decision (the
# notes, the title, the tag all being statements), and a workflow that created
# one on the way past would be publishing an announcement nobody wrote.
if ! assets=$(gh api "repos/$slug/releases/tags/$TAG" --jq '.draft as $d | .assets[] | "\(.name)\t\(.size)\t\(.digest // "-")"' 2>/tmp/rel.err); then
  echo "::error::no release with tag $TAG in $slug. The release is created deliberately before a run is dispatched; this stage only attaches to it."
  sed -e 's/^/  gh| /' /tmp/rel.err
  exit 1
fi
if gh api "repos/$slug/releases/tags/$TAG" --jq '.draft' | grep -qx true; then
  echo "::warning::the release $TAG is a draft, so the asset will not be visible until it is published"
fi
echo "--- assets already on it ---"
if [ -n "$assets" ]; then printf '%s\n' "$assets" | sed -e 's/^/  /'; else echo "  (none)"; fi

# The names as they stand, kept for the comparison after the upload. Names and
# not the whole rows: what this stage must not do is remove or replace an asset,
# and a row that changed in any other way would not be this stage's doing.
# `awk NF` rather than `grep -v '^$'`: an empty list would make grep exit 1, and
# under `pipefail` that is a status the assignment would pass on.
before=$(printf '%s\n' "$assets" | cut -f1 | awk 'NF' | sort || true)

here=$(printf '%s\n' "$assets" | awk -F'\t' -v n="$dmg_name" '$1==n {print $2"|"$3}')
if [ -n "$here" ]; then
  old_size="${here%%|*}"; old_digest="${here#*|}"
  if [ "$old_digest" = "$digest" ]; then
    echo "already published, and identical: $dmg_name ($size bytes, $digest) - nothing to do"
    {
      echo '### The macOS disk image'
      echo
      echo "\`$dmg_name\` is already on release \`$TAG\` in \`$slug\` with the"
      echo "same sha256 this run built (\`$digest\`), so it was left alone."
    } >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
    exit 0
  fi
  echo "::error::$slug's release $TAG already carries an asset named $dmg_name, and it is not the one this run built."
  echo "   on the release: $old_size bytes, $old_digest"
  echo "   this run built: $size bytes, $digest"
  echo "   Nothing is overwritten from here. If the new image should replace it, delete the asset on the release and dispatch again; if the old one is right, this run's image is a rebuild of the same version and the difference is in the build rather than in the upload."
  exit 1
fi

# No --clobber, deliberately: the check above is what decides, and passing the
# flag would also re-decide it for anyone who later rearranges this script.
gh release upload "$TAG" "$dmg" -R "$slug"

# Read back off the release rather than off gh's exit status: what matters is
# that the asset is there, at the size and hash this run built, and that is a
# question only the API answers.
if ! after=$(gh api "repos/$slug/releases/tags/$TAG" --jq '.assets[] | "\(.name)\t\(.size)\t\(.digest // "-")\t\(.url)"'); then
  echo "::error::the upload returned but the release cannot be read back"; exit 1
fi
got=$(printf '%s\n' "$after" | awk -F'\t' -v n="$dmg_name" '$1==n {print $0}')
if [ -z "$got" ]; then
  echo "::error::$dmg_name is not on the release after the upload:"; printf '%s\n' "$after" | sed -e 's/^/  /'; exit 1
fi
got_size=$(printf '%s' "$got" | cut -f2)
got_digest=$(printf '%s' "$got" | cut -f3)
got_url=$(printf '%s' "$got" | cut -f4)
if [ "$got_size" != "$size" ]; then
  echo "::error::the asset on the release is $got_size bytes, not the $size this run built"; exit 1
fi
if [ "$got_digest" != "-" ] && [ "$got_digest" != "$digest" ]; then
  echo "::error::the asset's digest on the release is $got_digest, not the $digest this run built"; exit 1
fi

# The additive rule, as a reading. Everything that was on the release before the
# upload has to still be there, and the only name that may have appeared is this
# run's. Both halves are needed: a member of `before` that vanished says the
# upload replaced a release rather than adding to one, and a name in `after`
# that is neither says an upload arrived carrying more than it was handed.
#
# Through files rather than through process substitution, because a release with
# no assets yet yields an empty list and `comm` would then report the blank line
# as a line of its own - a refusal invented by the comparison itself.
before_file=$(mktemp); after_file=$(mktemp)
if [ -n "$before" ]; then printf '%s\n' "$before" > "$before_file"; fi
printf '%s\n' "$after" | cut -f1 | awk 'NF' | sort > "$after_file"
lost=$(comm -23 "$before_file" "$after_file") || {
  echo "::error::the two asset lists could not be compared, so the additive rule was not checked"; exit 1; }
added=$(comm -13 "$before_file" "$after_file") || {
  echo "::error::the two asset lists could not be compared, so the additive rule was not checked"; exit 1; }
if [ -n "$lost" ]; then
  echo "::error::these assets were on the release before the upload and are not on it now, so the upload was not additive:"; printf '%s\n' "$lost" | sed -e 's/^/  - /'; exit 1
fi
if [ "$added" != "$dmg_name" ]; then
  echo "::error::the upload added '$added', expected only '$dmg_name'"; exit 1
fi
kept=$(comm -12 "$before_file" "$after_file" || true)
rm -f "$before_file" "$after_file"
echo "attached: $got_url"
if [ -n "$kept" ]; then
  echo "left as they were: $(printf '%s' "$kept" | tr '\n' ' ')"
else
  echo "it was the release's first asset"
fi

{
  echo '### The macOS disk image'
  echo
  echo "Attached to release \`$TAG\` of \`$slug\`:"
  echo
  echo '```'
  printf '%s\n' "$after" | sed -e 's/\t/  /g'
  echo '```'
  echo
  echo "Read back off the release, not off the upload's exit status: $size"
  echo "bytes and \`$digest\`, which is what this run built."
  echo
  if [ -n "$kept" ]; then
    echo 'The assets this run did not build were left as they were, which is'
    echo 'the whole of what "additive" means here:'
    echo
    echo '```'
    printf '%s\n' "$kept"
    echo '```'
  else
    echo 'It was the release'"'"'s first asset, so there was nothing to leave'
    echo 'alone.'
  fi
  if [ "$got_digest" = "-" ]; then
    echo
    echo 'The release API reported no digest for the asset, so only the size'
    echo 'was compared. The no-clobber check above falls back the same way:'
    echo 'an asset whose hash cannot be read is never treated as identical.'
  fi
} >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
