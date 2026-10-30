#!/usr/bin/env bash
#
# The Qt pairing a bottle and the machines around it have to agree about, in one
# place because all three Homebrew stages source it: ci/pack-brew.sh for the index
# refresh below, ci/runtime-brew.sh before it runs the recipe's test block, and
# ci/dev-brew.sh before the consumer builds against what was poured.
#
# Why the question exists at all. Stage A bottles on one runner and stage B / C
# pour on others, and Qt reaches each of them from its own machine's Homebrew
# index: the formula names `qtbase`, `qtdeclarative` and `qtwebsockets` with no
# version, so nothing ties the Qt a bottle was linked against to the Qt the
# pouring runner installs beside it. And those indexes are not the same one - a
# runner image carries the index as it stood when the image was built, and the
# images of a single run are not built together. Measured on this line twice. One
# run: stage A poured `qtbase 6.12.0_1` and the stage B job minutes later poured
# `6.11.2_1`. A later one, same attempt, all three stages: A `6.11.2_1`, B
# `6.12.0_1`, C `6.11.2_1`. A bottle built against one does not load against the
# other, and what the stage reports is dyld's
#
#   dyld: Symbol not found: __ZN8QVariantC1EO7QString
#
# which reads as a defect in QMdmm rather than as three runners built at three
# times disagreeing about a dependency. This file is both halves of the answer:
# the refresh that keeps it from happening, and the sentence for when it happens
# anyway.
#
# It is the same shape as the ref skew ci/resolve-ref.sh closed: the pieces of one
# run have to come from one tree. There the tree was in question and the toolchain
# was not; here it is the other way round.
#
# What each reading is. The bottle's side is the bottle's own
# INSTALL_RECEIPT.json - Homebrew writes it from the building machine's tab and
# carries it inside the bottle, so it is stage A's bytes rather than something a
# later stage derives. The runner's side is `brew list --versions` after the pour,
# i.e. a fact about this machine rather than what its index was expected to
# resolve to. Nothing here is pinned: the point is to report the pairing, not to
# make one happen, and Homebrew has no way to install an older Qt anyway.
#
# The file has two halves, and they are not the same job. brew_refresh_index below
# is what keeps the stages from resolving different Qts in the first place;
# everything under it is what says so when they do anyway.

# The index every reading in this file is taken against, refreshed once at the top
# of each stage before anything is installed.
#
# A runner image carries Homebrew's index as it stood when the image was built, and
# the images are not rebuilt together: measured in one run of this line, stage A's
# runner resolved qtbase 6.11.2_1, the stage B runner that followed minutes later
# resolved 6.12.0_1, and the stage C runner 6.11.2_1 again - three machines, one
# attempt, two indexes. Refreshing first makes all three read the index as it
# stands now, so the Qt a bottle is built against and the Qt the pouring runner
# installs come from one answer rather than from three image ages.
#
# Explicit rather than left to Homebrew's own before-an-install update: the
# workflow sets HOMEBREW_NO_AUTO_UPDATE, so the one refresh happens here, at a
# point this file can name, once per stage.
#
# A refresh that fails leaves the stage about to resolve its dependencies from an
# index of unknown age, which is the skew above arriving silently - so it stops
# here rather than carrying on.
brew_refresh_index() {
  if ! brew update; then
    echo "::error::the Homebrew index could not be refreshed, so this stage would resolve its Qt dependencies from whatever index its runner image was built with. That is how stage A and the stage pouring its bottle come to disagree, and the disagreement does not announce itself: it surfaces later as dyld's \"Symbol not found\", or as a stage that passes about a pairing no user is handed."
    exit 1
  fi
  echo "the index this stage resolves dependencies against is now current"
}

# The Qt versions a bottle records for itself, one "name<TAB>pkg_version" per
# line. The receipt also names 30-odd other dependencies; only the Qt ones are
# this file's business.
#
# A module the receipt does not name is not printed, so a caller has to tell
# "absent" from "read failed" - both come out as no line, and
# brew_assert_qt_pairing reports both rather than skipping either.
brew_bottle_qt_dependencies() {  # <bottle.tar.gz>
  local bottle=$1 receipt
  receipt=$(tar -xzOf "$bottle" '*/INSTALL_RECEIPT.json' 2>/dev/null) || return 0
  [ -n "$receipt" ] || return 0
  # python3 where the image has one, ruby where it does not - the same pair
  # ci/runtime-brew.sh serves its own bottle with, for the same reason: a macOS
  # runner is not guaranteed either, and both can read JSON.
  if command -v python3 >/dev/null; then
    printf '%s' "$receipt" | python3 -c '
import json, sys
for row in json.load(sys.stdin).get("runtime_dependencies", []):
    name = row.get("full_name", "")
    if name.startswith("qt"):
        print(name + "\t" + str(row.get("pkg_version", "")))
'
  elif command -v ruby >/dev/null; then
    printf '%s' "$receipt" | ruby -rjson -e '
JSON.parse(STDIN.read).fetch("runtime_dependencies", []).each do |row|
  name = row["full_name"].to_s
  puts "#{name}\t#{row["pkg_version"]}" if name.start_with?("qt")
end
'
  else
    echo "::error::neither python3 nor ruby is on this runner, so the bottle's own receipt cannot be read and this stage cannot say which Qt the bottle was linked against"
    return 1
  fi
}

# One module's pairing, stated: prints the two versions, or exits 1 with the
# disagreement as its first sentence.
#
# Both versions are arguments rather than readings taken here, so that the
# comparison can be exercised - locally, and in the change that introduced it -
# without a bottle of the other version existing anywhere. The strictness is
# deliberate: the upstream version has to match, and a difference in the
# revision suffix alone ("6.12.0_1" against "6.12.0_2") is a rebuild of the same
# Qt and is only reported. That is the same line Homebrew itself draws between a
# new version and a rebuilt one.
brew_assert_qt_pairing() {  # <bottle path> <module> <bottle version> <runner version>
  local path=$1 module=$2 bottle=${3:-} runner=${4:-} file
  file=$(basename "$path")
  if [ -z "$bottle" ]; then
    echo "::error::$file records no $module, and the formula depends on it, so this stage cannot say which Qt the bottle was linked against - and a reading it cannot take is not one it may skip. The bottle's own receipt is the source:"
    echo "  tar -xzOf $path '*/INSTALL_RECEIPT.json'"
    exit 1
  fi
  if [ -z "$runner" ]; then
    echo "::error::$module is not installed on this runner, so there is no pairing to read: the bottle was built against $module $bottle and nothing here poured one. The dependency assertions above are where this belongs if they passed."
    exit 1
  fi
  if [ "${bottle%%_*}" != "${runner%%_*}" ]; then
    echo "::error::$file was built against $module $bottle, and this runner has $runner. Nothing in the formula ties the two together - it names the module, not a version - so this is two Homebrew indexes disagreeing rather than a defect in QMdmm, and what follows would either be dyld's \"Symbol not found\" or a stage that passes about a pairing no user is handed. Stage A's runner had $module $bottle; the runner pouring the bottle has $runner."
    exit 1
  fi
  echo "the bottle was built against $module $bottle, and this runner has $runner"
}

# The three modules the line's formula depends on, as the one call both stages
# make: the pairing only means something for a module the formula declares, and
# the two stages care about the same three - naming them once here keeps a module
# added on one face from being verified on neither.
brew_assert_bottle_qt_is_the_runners() {  # <bottle path>
  local path=$1 module
  for module in qtbase qtdeclarative qtwebsockets; do
    brew_assert_qt_pairing "$path" "$module" \
      "$(brew_bottle_qt_dependencies "$path" |
         awk -v m="$module" '$1 == m { print $2; exit }')" \
      "$(brew list --versions "$module" 2>/dev/null | awk '{print $2}')"
  done
}
