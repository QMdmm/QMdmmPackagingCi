# release/

The publishing half of this repository: the stages that turn a packaging run
into a **signed, published** repository. `ci/` is the daily verification half and
is untouched by any of this — a release reuses `ci/pack-*.sh`, `ci/runtime-*.sh`
and `ci/dev-*.sh` exactly as the daily run does, and adds the stages below.

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
| `publish-brew.sh` | publish: stage the bottle, write its address into the formula | CI, publish job | nothing |
| `publish-macos.sh` | publish: attach the `.dmg` to the product repository's release | CI, publish job | **a token for the product repository** |
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

They also publish to two different places, which is the part worth stating
plainly:

* **the bottle goes to the site**, beside the twelve package lines and under the
  same `GITHUB_TOKEN` the rest of the publish job uses, because that address is
  the repository the whole publication lives in. `publish-brew.sh` stages it and
  writes the address into the formula in one step, so the URL and the file it
  names cannot come from two different opinions. The formula a tap should carry
  is published beside the bottle as `brew/qmdmm.rb`.
* **the `.dmg` goes to the product repository's release**, because it is not an
  input to a recipe - it is the product, and the page a person downloads it from
  is the product's own. No token a workflow is issued can write there, so this is
  the one stage in this directory that carries a credential of its own
  (`PRODUCT_RELEASE_TOKEN`, the `publish-macos` job). It attaches to a release
  that already exists and never overwrites an asset; the reasoning is at the top
  of the script.

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
