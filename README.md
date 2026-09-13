# qmdmm-packaging-ci

Container-based packaging verification for [Fsu0413/QMdmm](https://github.com/Fsu0413/QMdmm).

This repository holds no product code. It exists to answer three questions about
every distribution QMdmm claims to support, using that distribution's own
container:

| Stage | Question |
|---|---|
| **A pack** | Does a release build inside this distribution produce a complete, self-consistent set of packages? |
| **B runtime** | In a *clean* container of the same distribution, does installing only the runtime package give a program that runs? |
| **C dev** | In another clean container, is the dev package enough to build QMdmm's own GUI and Bot from source? |

## Why the stages do not share a container

Stage A has a full toolchain, Qt's development packages and the compiled source
tree on disk. If stages B and C ran there, a missing runtime dependency would be
masked by whatever was already installed and "minimal but complete" could never
be disproved. Each stage therefore gets a fresh container of the same image, and
stages B and C install **only** what the packages themselves pull in.

The same reasoning is why stages B and C install through a local repository built
from the produced packages instead of pointing the package manager at a file: a
local repository is the only way the declared inter-component dependencies
(`qmdmm-6-dev` → `qmdmm-6` + `qmdmm-common-dev`, and the `-devel` equivalents)
actually get resolved rather than sidestepped.

## Package names

The dev packages follow each distribution's own convention:

| component | Debian | Fedora |
|---|---|---|
| `6` (runtime) | `qmdmm-6` | `qmdmm-6` |
| `dev6` (dev) | `qmdmm-6-dev` | `qmdmm-6-devel` |
| `dev-common` (headers) | `qmdmm-common-dev` | `qmdmm-common-devel` |
| `doc` | `qmdmm-doc` | `qmdmm-doc` |

The workflow does not hardcode these: stage A reads the real names back out of
the produced packages and writes `MANIFEST.tsv`, and stages B and C select on the
suffix recorded in the matrix. The suffixes in the matrix are therefore also an
assertion — if a package ends up named something else, stage A fails.

## Acceptance criteria

**Stage B** — after installing only the runtime package and running the repair
command (`apt-get -f install` on Debian, an idempotent `dnf install` plus a
`dnf check --dependencies` audit on Fedora):

* `ldd` reports **zero** unresolved libraries for every installed QMdmm binary
  and shared library.
* `QT_QPA_PLATFORM=offscreen timeout 20 QMdmm6` is still running when the timeout
  fires (`rc` 124), i.e. the GUI really starts and does not fall over.
* `QMdmmServer6` and `QMdmmBot6` start without a dynamic loading failure.

**Stage C** — after installing only the dev package by name and running the same
repair pass:

* `find_package(QMdmm6 0.0.1 REQUIRED COMPONENTS Core Networking)` succeeds.
* QMdmm's own `QMdmmGui` and `QMdmmBot` directories build through
  `add_subdirectory` against `QMdmm6::Core` / `QMdmm6::Networking`, producing
  `QMdmm6` and `QMdmmBot6` executables.
* Those executables have no unresolved libraries and survive under `offscreen`.

The "minimal" half of "minimal but complete" is reported rather than enforced:
the job summary records what the repair pass had to add, and what installing only
the dev package dragged in. Declaring the dependencies correctly is what makes
that list empty.

## `consumer/`

The acceptance harness for stage C. It reaches into the QMdmm source tree for
exactly one thing — the GUI and Bot sources — and takes everything else from the
installed package:

* `find_package(QMdmm6 0.0.1 REQUIRED COMPONENTS Core Networking)`
* `api-smoke.cpp` uses both include spellings (`<QMdmmPlayer>` and
  `<QMdmmCore/QMdmmPlayer>`) and both target spellings (`QMdmm6::Core` and the
  generation-free `QMdmm::Core`)
* `add_subdirectory(<QMdmm>/QMdmmGui)` and `add_subdirectory(<QMdmm>/QMdmmBot)`
  build the real applications

Building QMdmm's own application directories is a much harsher test than a
hand-written consumer could be: it only works if the installed package exports
exactly the interface QMdmm links against internally.

## Running it

Manually:

```
gh workflow run packaging-smoke.yml -f qmdmm_ref=<branch|tag|commit>
gh run watch
```

Inputs:

* `qmdmm_ref` — the QMdmm ref to package and verify. Defaults to
  `packaging-consumer-support`, the branch that adds the exported CMake package.
* `build_type` — CMake build type, default `Release`.

Images: `debian:sid` and `fedora:latest` (the rolling pointers). Pinning per
release and adding `fedora:rawhide` as a non-blocking weekly run is left for a
later pass, once the manual flow is stable.
