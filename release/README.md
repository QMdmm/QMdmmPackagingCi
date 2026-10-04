# release/

The publishing half of this repository: the stages that turn a packaging run
into a **signed, published** repository. `ci/` is the daily verification half and
is untouched by any of this — a release reuses `ci/pack-*.sh`, `ci/runtime-*.sh`
and `ci/dev-*.sh` exactly as the daily run does, and adds the stages below. The
one stage this change added to `ci/` is `ci/merge-brew.sh`, and it belongs to the
release line alone: the daily run has one Homebrew row, so the block that row
writes names every bottle there is and stage B installs that formula as it
stands. Three rows is where a block stops being something one row can write,
which is the whole reason the merge stage exists.

## Where this came from

Everything here was developed and rehearsed in `nemn9852/qmdmm-signing-lab`, a
disposable repository that ran the whole scheme end to end with a throwaway
keyring and revoked it at the end. It is **moved here, not rewritten**: the
scripts in this directory are the ones whose behaviour was measured, and the
numbers they produced are in that repository's `FINDINGS.md`.

Practical consequence: **the comments still say "the lab"**. They are kept that
way on purpose. They record *why* the code is shaped as it is — which experiment
produced a rule, which wrong assumption cost a run — and rewriting the prose
would either lose that or make it up. Where a comment names a thing the lab
called differently (its repository was `lab`, so its package database was
`lab.db`), the name has been changed and the comment says so.

## The stages

| script | stage | runs on | holds |
|---|---|---|---|
| `assert-revision-tag.sh` | guard | CI | nothing |
| `sign-repo-<fmt>.sh` | S sign | CI, in the row's own image | **that line's subkey** |
| `mkrepo-debian.sh` | (helper for S/deb) | CI | the key it is handed |
| `check-fingerprints.sh` | gate in the publish job | CI | nothing |
| `publish-brew.sh` | publish: stage the bottles, write their address into the formula | CI, publish job | nothing |
| `publish-macos.sh` | publish: attach the `.dmg` to the product repository's release | CI, publish job | **a token for the product repository** |
| `publish-tap.sh` | publish: put this release's formula into the Homebrew tap | CI, publish job | **the same token** |
| `consume-<consumer>.sh` | trust: install and verify as a consumer | CI, clean container | nothing |
| `consume-apt-keyring.sh`, `consume-keyring-package.sh`, `consume-dnf-keyring-package.sh` | trust: the keyring bootstrap | CI, clean container | nothing |
| `mkkeyring-deb.sh`, `mkkeyring-rpm.sh` | build the root-signed keyring source | **a trusted machine, never CI** | the **root** key |
| `lib-tools.sh`, `lib-site.sh` | shared helpers | — | — |
| `lines.tsv` | the line list | — | — |

`mkkeyring-*.sh` read `$HOME/qmdmm-signing-prod/env.sh` for `GNUPGHOME`, `ROOT`
and the line fingerprints. There is no such file in this repository and there
must not be: the root secret never enters CI, which is what makes the
root-signed keyring source a trusted-machine step rather than a workflow one.

## The two macOS faces, and why they publish apart

The macOS lines are not rows of the other three stages' matrices - a macOS
runner cannot run a Linux container, and `runs-on` and `container:` are job-level
keys - so they run as a group of their own in `release.yml`. Neither signs
anything: a bottle is verified by the checksum in the formula that points at it
and the `.dmg` by the ad-hoc signature `macdeployqt` applies, and neither has a
subkey to sign with.

The Homebrew line is **three rows per stage** - `macos-15`, `macos-26` and
`xcode-27`, i.e. macOS 15 Sequoia, 26 Tahoe and 27 - where the `.dmg` line is
one, and that is the product rather than the platform. A `.dmg` is one
self-contained bundle; a bottle is a binary built on one exact macOS version,
and the tag it is published under is the compatibility floor: a macOS older than
the runner cannot pour it, and a macOS newer than every tag pours the newest
line below it. One row therefore answers "does the bottle work" for exactly one
macOS, and `ci/pack-brew.sh` refuses a row whose runner is not the macOS it
declares because nothing downstream could tell.

No single row can write the block the **published** formula carries, which has one
checksum per version: the row that bottled on 15 knows nothing about the other
two. Each row does write a block - the one naming the bottle it built, which is
the whole block on the daily line's single row - and on this line those three
one-line blocks are an intermediate state nothing publishes. **`merge-brew`** -
one job, after all of them - turns the rows' JSONs into the one block with
Homebrew's own `brew bottle --merge`, over one row's formula, and refuses to merge
if the rows are not the set the workflow declared, if they did not pin the same
source (compared with each row's own block taken off both sides, since that is
the one part of the file rows are meant to differ in), or if the block's tags or
order are not the ones expected. That order is behaviour rather than formatting
(Homebrew walks the block in file order when it looks for a bottle for a macOS
newer than every tag), so it is read back rather than assumed. The merge job runs
on an arm64 macOS runner because the JSONs name their formula through Homebrew's
repository layout.

`merge-brew`'s output is the artifact the stages after it consume, under the name
`pack-brew` - one directory holding every bottle this run built, the formula
carrying the block, and a manifest naming each bottle. Every stage from there on
reads this row's bottle **out of that manifest by tag** rather than taking the
first file in the directory, and B and C assert that the file Homebrew poured is
the one their own tag names: pouring a neighbouring row's bottle is the one
failure that would otherwise be green twice over.

They also publish to three different places, and the last two are why this
directory holds a credential at all:

* **the bottles go to the site**, beside the twelve package lines and under the
  same `GITHUB_TOKEN` the rest of the publish job uses, because that address is
  the repository the whole publication lives in. `publish-brew.sh` stages every
  bottle the manifest names and writes the address into the formula in one step,
  so the URL and the files it names cannot come from two different opinions. The
  formula a tap should carry is published beside them as `brew/qmdmm.rb`.
* **that formula goes into the tap**, because a bottle no formula points at has
  not been published: the address a user's `brew install` reads is the one in
  `QMdmm/homebrew-qmdmm`. `publish-tap.sh` fetches the formula back off the site
  rather than taking the artifact the publish job staged, so what reaches the tap
  is the bytes a user can get; it fetches and hashes **every** bottle the block
  names before writing anything, because a pour is per machine; and it may
  rewrite only the pin and the bottle block, because the recipe itself is
  hand-written and not this workflow's to edit.
* **the `.dmg` goes to the product repository's release**, because it is not an
  input to a recipe - it is the product, and the page a person downloads it from
  is the product's own.

No token a workflow is issued can write to either of the last two places, so one
credential covers both jobs: `CROSS_REPO_TOKEN`, scoped to `QMdmm/QMdmm` and
`QMdmm/homebrew-qmdmm` and to nothing else. The `.dmg` stage attaches to a
release that already exists and never replaces an asset: one already under the
name means the release is written once and this run attaches nothing, so a
second dispatch of the same tag is a no-op rather than a failure. The tap stage
compares what it is about to push against the tap and refuses anything beyond
the pin and the block. The reasoning for each is at the top of its script.

## Rehearsing a script here

Every script under `release/` runs on the publish job's **ubuntu-latest** runner,
while the scripts under `ci/` run on the platform they pack for — the Homebrew
ones on macOS. That difference is not only about which tools exist. The same
pattern can be read differently by two `grep`s, and a rehearsal on the wrong one
certifies a gate that cannot pass where it actually runs.

The case that put this section here: the manifest header check in
`publish-brew.sh` was written

    head -1 "$manifest" | grep -qE '^package\tversion\ttag\tfile$'

`\t` is a tab to BSD grep (what this machine has) and a stray escape to GNU grep
(what the runner has), where it becomes a literal `t` — so the pattern matched
no header at all and refused every manifest, with `grep: warning: stray \ before
t` sitting three lines above the refusal. Rehearsed here, it passed. The line
reads four fields now (`IFS=$'\t' read`), which has no engine inside it.

So when rehearsing one of these scripts on a machine that is not the runner, put
the runner's tools first:

    mkdir -p /tmp/gnu-tools
    ln -sf "$(command -v ggrep)" /tmp/gnu-tools/grep
    ln -sf "$(command -v gsed)"  /tmp/gnu-tools/sed
    PATH=/tmp/gnu-tools:$PATH bash <the rehearsal>

and give the shim teeth by also running it against the script as it was *before*
the change: it has to reproduce what the runner did. `awk` is the remaining gap
here — this machine has neither `mawk` nor `gawk`, so `awk` patterns are still
reasoned about rather than read under the runner's engine.

## What is not here

* **`rotate-line-local.sh`** — the rotation tool, still in the lab. It is on the
  path a line takes *after* a leak rather than on the path to a first release,
  and its env-file rewriting assumes the lab's layout. It needs its own pass.
* **The keyring material under `site/`** — the deb archive-keyring packages and
  the rpm `*-release` packages, all root-signed. These are built off-CI by the
  `mkkeyring-*.sh` tools above and committed at their published path, **one
  directory per suite / per version** (`site/debian-keyring/<suite>/`,
  `site/fedora-keyring/<version>/`): each package bakes the distribution it
  configures into the consumer's `sources.list.d`, so one directory serving two
  of them would be able to hand a consumer the wrong one. `mkkeyring-deb.sh`
  carries the full argument at its top.
* **The Alpine line.** `apk` signs inside stage A rather than in a signing stage
  of its own (abuild cannot be told not to sign), and the lab never exercised
  that line at all — it is the one line whose release path is undesigned rather
  than merely unported.
