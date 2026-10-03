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
| `consume-<consumer>.sh` | trust: install and verify as a consumer | CI, clean container | nothing |
| `consume-apt-keyring.sh`, `consume-keyring-package.sh`, `consume-dnf-keyring-package.sh` | trust: the keyring bootstrap | CI, clean container | nothing |
| `mkkeyring-deb.sh`, `mkkeyring-rpm.sh` | build the root-signed keyring source | **a trusted machine, never CI** | the **root** key |
| `lib-tools.sh`, `lib-site.sh` | shared helpers | — | — |
| `lines.tsv` | the line list | — | — |

`mkkeyring-*.sh` read `$HOME/qmdmm-signing-prod/env.sh` for `GNUPGHOME`, `ROOT`
and the line fingerprints. There is no such file in this repository and there
must not be: the root secret never enters CI, which is what makes the
root-signed keyring source a trusted-machine step rather than a workflow one.

## What is not here

* **`rotate-line-local.sh`** — the rotation tool, still in the lab. It is on the
  path a line takes *after* a leak rather than on the path to a first release,
  and its env-file rewriting assumes the lab's layout. It needs its own pass.
* **The keyring material under `site/`** — the deb archive-keyring package and
  the rpm `*-release` packages, all root-signed. These are built off-CI by the
  `mkkeyring-*.sh` tools above and committed at their published path. Nothing
  has been built yet.
* **The Alpine line.** `apk` signs inside stage A rather than in a signing stage
  of its own (abuild cannot be told not to sign), and the lab never exercised
  that line at all — it is the one line whose release path is undesigned rather
  than merely unported.
