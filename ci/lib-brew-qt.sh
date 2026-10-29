#!/usr/bin/env bash
#
# The Qt pairing a bottle and the machine pouring it have to agree about, in one
# place because both consuming stages ask it: ci/runtime-brew.sh before it runs
# the recipe's test block, ci/dev-brew.sh before the consumer builds against what
# was poured.
#
# Why the question exists at all. Stage A bottles on one runner and stage B / C
# pour on others, and Qt reaches each of them from its own machine's Homebrew
# index: the formula names `qtbase`, `qtdeclarative` and `qtwebsockets` with no
# version, so nothing ties the Qt a bottle was linked against to the Qt the
# pouring runner installs beside it. While a fleet is mid-rollout those are two
# different indexes - measured once in one run: stage A poured `qtbase 6.12.0_1`
# and the stage B job that followed minutes later poured `6.11.2_1`, same macOS,
# same architecture - and a bottle built against one does not load against the
# other. What the stage then reports is dyld's
#
#   dyld: Symbol not found: __ZN8QVariantC1EO7QString
#
# which reads as a defect in QMdmm rather than as two runners disagreeing about a
# dependency. This file is the sentence that says so first.
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
