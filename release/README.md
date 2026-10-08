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

Eight lines are published. Seven of them are OpenPGP lines — debian, ubuntu,
fedora, rocky, alma, arch and manjaro — and their twelve rows are the matrices of
the three stages above. Alpine is a job group of its own with five rows, and the
two macOS faces are a third. Every line's shape is different enough to need its
own section below; what they share is that a consumer's position is what gets
asserted, in a clean container, with no secret in reach.

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
| `assert-revision-tag.sh` | guard: the ref is a tag | CI | nothing |
| `assert-release-version.sh` | guard: the tag, its tree and the recipes carry one version | CI | nothing |
| `sign-repo-<fmt>.sh` | S sign | CI, in the row's own image | **that line's subkey** |
| `mkrepo-debian.sh` | (helper for S/deb) | CI | the key it is handed |
| `check-fingerprints.sh` | gate in the publish job | CI | nothing |
| `publish-brew.sh` | publish: stage the bottles, write their address into the formula | CI, publish job | nothing |
| `publish-macos.sh` | publish: attach the `.dmg` to the product repository's release | CI, publish job | **a token for the product repository** |
| `publish-tap.sh` | publish: put this release's formula into the Homebrew tap | CI, publish job | **the same token** |
| `consume-<consumer>.sh` | trust: install and verify as a consumer (`apt`, `dnf`, `pacman`, `apk`) | CI, clean container | nothing |
| `consume-apt-keyring.sh`, `consume-keyring-package.sh`, `consume-dnf-keyring-package.sh` | trust: the keyring bootstrap | CI, clean container | nothing |
| `mkkeyring-deb.sh`, `mkkeyring-rpm.sh` | build the root-signed keyring source | **a trusted machine, never CI** | the **root** key |
| `lib-tools.sh`, `lib-site.sh` | shared helpers | — | — |
| `lines.tsv` | the line list | — | — |

`mkkeyring-*.sh` read `$HOME/qmdmm-signing-prod/env.sh` for `GNUPGHOME`, `ROOT`
and the line fingerprints. There is no such file in this repository and there
must not be: the root secret never enters CI, which is what makes the
root-signed keyring source a trusted-machine step rather than a workflow one.

A line's key file under `keys/` is **a set rather than one file**, and a rotation
window is the state where that set has two members: the export being retired
stays beside the live one until a later release deletes it. Two shapes carry it
and `release/mkkeyring-deb.sh` accepts both — a single file that already carries
both subkeys, which is what rotating a line's own primary produces and is the
shape that reaches every consumer path (the site publishes `keys/` verbatim and
the consumer cells fetch `qmdmm-packages.gpg` by that name), or the retired
export dropped in as a second file, which the tool merges into the one keyring
file the package's `Signed-By` names. The second shape is the one that until now
existed and did nothing: a file sitting beside the live one was installed nowhere
and read by nothing, so a rotation staged that way would have gone out carrying
one key and looking correct. The lifecycle and the reasoning are at the top of
the tool, and the tools that produce those exports (`rotate-line-local.sh`) are
still in the lab — see below.

`assert-release-version.sh` is the guard's second question, and the reason there
is a second one at all. `packaging/arch/PKGBUILD` and
`packaging/alpine/APKBUILD` carry a version of their own — they are files
somebody can build from by hand, with the version they say — while the deb, rpm,
Homebrew and macOS lines take theirs from the tagged tree, and no stage compares
the two. A release dispatched with them apart would publish packages of two
different versions in one repository with every stage green, and the version is
not a field any of those stages reads. The check sits on the release path rather
than inside `ci/pack-*.sh` because those scripts are also the daily run's, and
the daily run packages `main` rather than a tag: a version check there would turn
every version bump into a red daily run until somebody edited a recipe here.
Syncing the recipes is a step of declaring the release — that is the whole of it
— and this is what makes forgetting that step loud instead of silent.

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

## The Alpine face

Alpine runs as a job group of its own for two structural reasons, and only the
first is about packaging.

**It has no stage S.** `abuild` signs every package and the repository index
unconditionally — it cannot be told not to, and it dies without a key — so
`ci/pack-apk.sh` already finishes with a signed `APKINDEX.tar.gz` beside signed
packages. What stage A produced IS what gets published, which is why the
`publish` job waits on all three of the Alpine rows — `pack-apk` *and* both
verify jobs — while it waits only on `sign` for the other seven lines: stages B
and C reach `publish` by way of the signing stage, which collects them, and this
line has no stage S for anything to collect. On this line the first stop after
packing is the published repository. A repository, not a `foo.db` or a
`dists/`: apk appends `<arch>/APKINDEX.tar.gz` to whatever address a consumer
names, so the site's `alpine/<version>/` holds the architecture directory and
nothing else, and the MANIFEST stage A writes alongside it is dropped rather
than published — it is this harness's bookkeeping and not a file any apk asks a
repository for.

**Its signing key comes out of an environment.** `environment:` is a job-level
key in `release.yml`, so a row that needs one cannot share a job with the twelve
rows that must not have one. Those are deliberately environment-free, and
keeping them that way is what makes "a packaging line cannot see a signing
secret" a property of the layout rather than a property of everybody's care.

Two keys, and they are different files rather than two names for one:

* `qmdmm-daily-<hex>` signs the daily smoke build. Its private half is the
  repository-level `PACKAGER_PRIVKEY` and nothing it signs is ever published, so
  no consumer is ever told to trust it.
* `qmdmm-release-<hex>` is the only key a consumer of a published repository
  should end up with, and its private half is the `alpine` environment's
  `SIGNING_KEY`. Here the NAME is the whole identity — apk resolves a package's
  signature by looking for a file called `.SIGN.RSA.<basename>` in
  `/etc/apk/keys`, and apk has no revocation of any kind — so rotating it can
  only mean generating a new name and asking every consumer to delete the old
  file by hand.

There is no keyring source on this line, unlike deb and rpm: apk has no
convention of a package that carries a key, and the whole consumer action is
putting that one file in `/etc/apk/keys` and naming the repository. What the
publish job stages is therefore the key file itself, at `keys/alpine/`, beside
the other lines' key material — and the front page prints `sha256(DER)` of it,
which is what abuild itself reports for such a key and the only reading that
gives it an identity other than the file. That value is derived from the key
file as the page is written, so it is the one line's reading on the front page
that cannot drift from the key it names; `release/check-fingerprints.sh` says so
where it walks the list.

`release/consume-apk.sh` is the cell that reads the claim, and its negative half
is where the two-key design is measured: it installs the release key from the
site, updates, and installs; then it does the whole thing again with the *daily*
key in the release key's place, which must be refused. The daily key is the
right wrong key — it is public, it signs the daily build, and a consumer who went
looking could find it — where a key nobody could obtain would prove less.

The five versions are `3.21`, `3.22`, `3.23`, `3.24` and `edge`: one row per
Alpine release, and the same five rows in each of the three stages. `alpine:latest`,
which the daily line tests, is deliberately not one of them — a published
repository has to name the release it serves, which is the same reason the other
matrices carry concrete versions. `3.24` is what `latest` currently is, and it is
listed beside the others so that the name in the path stays put when the floating
tag moves on.

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
* **`genesis-alpine-key.sh`**, the script that mints the Alpine release key and
  says where its name has to agree. It is the step a rotation starts from on
  that line, and a rotation there is not the same shape as on the other seven:
  there are no subkeys and no revocation, so it is a new name plus every
  consumer deleting the old file by hand. It is in the lab with
  `rotate-line-local.sh` because both are on the path a line takes *after* a
  leak rather than on the path to a release.
