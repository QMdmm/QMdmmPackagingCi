# QMdmmPackagingCi

Container-based packaging verification for [QMdmm/QMdmm](https://github.com/QMdmm/QMdmm).

This repository holds no product code. It exists to answer three questions about
every distribution QMdmm claims to support, using that distribution's own
container:

| Stage | Question |
|---|---|
| **A pack** | Does a release build inside this distribution produce a complete, self-consistent set of packages? |
| **B runtime** | In a *clean* container of the same distribution, does installing only the runtime package give a program that runs? |
| **C dev** | In another clean container, is the dev package enough to build QMdmm's own GUI and Bot from source? |

Each of the three stages is one job with a matrix over the four distributions:
Debian and Fedora pack through cpack, Arch through makepkg, and Alpine through
abuild reading `packaging/alpine/APKBUILD`. What only one line needs is a
conditional step or an expression inside that shared job rather than a job of
its own. The questions are therefore asked once per distribution.

The shell lives in `ci/`, one entry script per distribution per stage, and each
one owns a whole stage rather than a step: `ci/pack-<kind>.sh`,
`ci/runtime-<kind>.sh`, `ci/dev-<kind>.sh`. A difference between distributions is
therefore a file rather than a branch inside a step, which is what lets a stage be
reused by the release packaging that produces the versioned artifacts. The package
list a stage installs is still a decision taken at the call site: it is handed to
`ci/base-image-<kind>.sh`, which refreshes the image and installs whatever it is
given — so stage A's toolchain, stage B's inspection tooling and stage C's plain
compiler are one implementation with three arguments.

The two questions stages B and C ask that are *not* per distribution are one
script per platform instead: `ci/runtime-verify-linux.sh`, and the pair
`ci/build-verify-linux.sh` + `ci/run-verify-linux.sh` (the rebuilt Server runs in
the first, while port 6366 is free, and the installed one in the second, so the
rebuilt Bot has something to talk to). Those three read `DIST_KIND` for the two
things that really do differ per line: the timeout's exit status and the loader's
wording.

Every job checks this repository out and downloads its artifacts *before* its
stage script runs, so a script never has to be split around a `uses:` step. The
three `Install bash` steps stay in the workflow — one per stage — because they
run under `sh`, before bash exists on Alpine, which is the one thing a
`#!/usr/bin/env bash` script cannot do. The two macOS stages carry an install of
their own for the same kind of reason: `gtimeout` is not in the image, and
coreutils is what provides it.

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

On Arch there are no inter-component dependencies to resolve — one package, no
components — and the repository is kept anyway: installing from it *by name* is
still what shows the package is findable and its declared Qt dependencies
resolvable.

Every job begins by bringing its own image up to date (`apt-get update` +
`apt-get dist-upgrade` on Debian, `dnf upgrade` on Fedora, `pacman -Syu` on
Arch, `apk update` + `apk upgrade --available` on Alpine). An image is a
snapshot, and installing onto a stale one would blend two different things
together: what the package under test declares, and whatever the base image was
simply missing. Refreshing first is what makes everything that lands afterwards
attributable to the packages being tested.

## Package names

The dev packages follow each distribution's own convention:

| component | Debian | Fedora | Arch | Alpine |
|---|---|---|---|---|
| `6` (runtime) | `qmdmm-6` | `qmdmm-6` | `qmdmm-6` | `qmdmm` |
| `dev6` (dev) | `qmdmm-6-dev` | `qmdmm-6-devel` | the same package | `qmdmm-dev` |
| `dev-common` (headers) | `qmdmm-common-dev` | `qmdmm-common-devel` | the same package | (none) |
| `doc` | `qmdmm-doc` | `qmdmm-doc` | not produced | `qmdmm-doc` |

Two of the four lines collapse the component split, for different reasons and to
different degrees. Arch has no mechanism for splitting a package into components
at all, and its line does not go through CPack in the first place: one package
answers both questions — stages B and C install the same file — so its recipe's
`depends` is the union of what the other lines' runtime and dev packages declare,
with no second package to carry the other half. That includes `qt6-tools` and
`cmake`, without which the headers and the CMake package riding along in the
runtime package could not be used. Alpine does split, through abuild's
`split_dev`: the headers, the dev `.so` symlinks and the CMake package config all
land in `qmdmm-dev`, so what the deb and rpm lines divide between `dev6` and
`dev-common` is one package there. Alpine's names carry no Qt generation either,
because Alpine splits by suffix convention rather than by an explicit package name.

The workflow does not hardcode these: stage A reads the real names back out of
the produced packages and writes `MANIFEST.tsv`, and stages B and C select on the
suffix recorded in the matrix. What a line must produce is recorded in the matrix
too (the `expect` field), which makes the shape an assertion as well — a package
ending up named something else, or an Arch run producing more than one, fails
stage A. Alpine is the exception on the packaging side: `qmdmm` is a prefix of
every other name there, so a suffix match would prove nothing and its own pack job
asserts the three exact names instead. Its rows in stages B and C still select
through the matrix, with a "suffix" that happens to be the whole name (`qmdmm`)
because the runtime package carries no Qt generation.

## Acceptance criteria

**Stage B** — after bringing the base up to date and installing only the runtime
package, settling the dependency set as far as that distribution's package manager
allows (`apt-get -f install` on Debian; a second, idempotent `dnf install` plus a
`dnf check --dependencies` audit on Fedora; `pacman -Dk`, a database audit, on
Arch, where a transaction is resolved whole and there is no half-installed state
to repair; and on Alpine the summary reports what the install added, because apk
resolves the whole transaction or fails):

* `ldd` reports **zero** unresolved libraries for every installed QMdmm binary
  and shared library.
* `QT_QPA_PLATFORM=offscreen timeout 20 QMdmm6` is still running when the timeout
  fires (`rc` 124), i.e. the GUI really starts and does not fall over.
* The installed `QMdmm6` carries its QML at `qrc:/qt/qml/QMdmm/Gui/qml` — the
  path `QMdmmGui/src/mainwindow.cpp` asks the resource system for. Staying alive
  is not enough of a proof on its own: with the resource prefix wrong the GUI
  does exactly that and shows an empty window, and the warning it prints in that
  case is not something every distribution puts on stderr. The check reads the
  binary instead (`strings -e l`: Qt stores these paths as UTF-16, so a plain
  grep finds nothing), which makes it hold everywhere, whatever the runtime
  happens to log.
* `QMdmmServer6` starts and stays up — it calls `qFatal()` when it cannot bind
  its sockets, so surviving is only possible if it listened.
* `QMdmmBot6 --host=qmdmm://localhost:6366` stays up **and** the server reports the
  connection it accepted. The exit status alone would prove nothing here: the Bot
  refuses to start without `--host` (exit 3), and with one it sits in its event
  loop even when nothing answers, because the client retries. The accepted
  connection is the part that shows the packaged client really got through over
  the packaged stack.

**Stage C** — after bringing the base up to date, installing only the dev package
by name — on Arch that is the same package stage B installed — and settling the
dependency set the same way:

* `find_package(QMdmm6 0.0.1 REQUIRED COMPONENTS Core Networking)` succeeds.
* QMdmm's own `QMdmmGui`, `QMdmmBot` and `QMdmmServer` directories build through
  `add_subdirectory` against `QMdmm6::Core` / `QMdmm6::Networking`, producing
  `QMdmm6`, `QMdmmBot6` and `QMdmmServer6` executables.
* Those executables have no unresolved libraries, the GUI resolves its own QML
  resources — read statically out of the rebuilt binary, with the same check as
  stage B, because here the prefix is decided by the consumer's own
  `qt6_standard_project_setup` — and the **rebuilt** Bot connects to the
  **installed** `QMdmmServer6` — so a source build against the dev package
  demonstrably talks to the packaged runtime.

The connection checks read `/proc/net/tcp` and `/proc/net/tcp6` (port 6366 is
`18DE`, `0A` is LISTEN, `01` is ESTABLISHED). Both tables, because the server
listens on `QHostAddress::Any`, which Qt maps to the dual-stack IPv6 wildcard, so
its socket shows up in `tcp6`. If a container ever hides those files the harness
warns and falls back to liveness rather than failing a sound package.

One criterion differs by distribution. `timeout` is GNU coreutils' on Debian and
Fedora and busybox's on Alpine, and busybox reports **143** (128 + SIGTERM) for a
child it had to kill where coreutils reports **124**. The Alpine stages therefore
accept `{0,124,143}` for anything they expect to survive, and filter the stderr of
every program they start for the loader's and the kernel's own words for a failure
(`error while loading`, `version ... not found`, `Segmentation`, `Aborted`)
instead.

The "minimal" half of "minimal but complete" is reported rather than enforced:
the job summary records what the repair pass had to add, and what installing only
the dev package dragged in — on Alpine the difference the install made to the
package set, since there is no repair pass there. Declaring the dependencies
correctly is what makes that list empty.

## `consumer/`

The acceptance harness for stage C. It reaches into the QMdmm source tree for
exactly one thing — the application sources — and takes everything else from the
installed package:

* `find_package(QMdmm6 0.0.1 REQUIRED COMPONENTS Core Networking)`
* `api-smoke.cpp` uses both include spellings (`<QMdmmPlayer>` and
  `<QMdmmCore/QMdmmPlayer>`) and both target spellings (`QMdmm6::Core` and the
  generation-free `QMdmm::Core`)
* `add_subdirectory(<QMdmm>/QMdmmGui)`, `(<QMdmm>/QMdmmBot)` and
  `(<QMdmm>/QMdmmServer)` build all three real applications
* `qt6_standard_project_setup(REQUIRES 6.7)`, mirroring QMdmm's own root

Building QMdmm's own application directories is a much harsher test than a
hand-written consumer could be: it only works if the installed package exports
exactly the interface QMdmm links against internally.

That `qt6_standard_project_setup` line is not a workaround, it is part of what
downstream projects have to do: `QMdmmGui/src/mainwindow.cpp` hardcodes
`qrc:/qt/qml/QMdmm/Gui/qml/main.qml`, and where a QML module's resources end up
is decided by the QTP0001 policy, which that call sets. Without it the rebuilt
GUI links, starts, and then shows an empty window.

## The Arch line

Arch answers the same three questions through the same three stages, with its own
package manager and its own recipe (`packaging/arch/PKGBUILD`, the file the local
run was verified with). Three things differ, all of them deliberately:

* **It packages with `makepkg`, not CPack.** The pack stage checks this repository
  out, builds the source tarball from the QMdmm ref with `git archive` — the
  recipe takes a local tarball, not a codeload download — and refreshes the
  recipe's `sha256sums` with `updpkgsums`, because the committed checksums pin the
  one ref that was verified locally while a run packages whatever ref it was
  given.
* **`makepkg` refuses to run as root**, and every step of a container job runs as
  root, so the pack stage creates an ordinary `builder` user and builds as it.
  Installing in stages B and C goes back to root: installing is not building.
* **Nothing is signed.** No signature is produced and none is required, so the
  local repository that stages B and C install from carries
  `SigLevel = Optional TrustAll`. That decision is confined to that one
  repository and never touches the system's own.

The pack stage is pack-only here exactly as it is on the other lines: tests
are not run in it, on any of the three.

## The Alpine line

Alpine differs from the other three in two things its scripts cannot get around:
it packs with abuild, which signs the packages and the repository index whether or
not anyone asked it to, and the image has no bash, so the workflow installs one
before any stage script can run.


Signing is not optional on Alpine: abuild calls `abuild-sign` for the packages and
for the repository index unconditionally and dies without a key. This repository
holds one half of a key pair and the repository settings hold the other.

* `packaging/alpine/neve-6aaaace6.rsa.pub` — the public half, copied into the
  consuming container's `/etc/apk/keys/` by stages B and C.
* the `PACKAGER_PRIVKEY` secret — the private half, written to
  `~builder/.abuild/neve-6aaaace6.rsa` in stage A, and nowhere else. Stage A
  hands it over on that line's row only: the environment variable carrying it is
  an expression on the matrix row, so the other three lines get an empty value.

The two file names have to agree: abuild derives each signature's file name from
the private key's own file name and apk resolves that name in `/etc/apk/keys`, so
a signature made with a differently named key is untrusted by construction. Stage
A asserts the two halves are the same pair before it builds anything, which turns
a mismatch into one clear message rather than an `UNTRUSTED signature` two stages
later.

The key is long-lived on purpose. The line could generate a throwaway key per run,
as the local verification did, but then the public half committed here would mean
nothing and no one could ever check a published package against it.

## The Homebrew line

The Homebrew line asks the same three questions on macOS through the same three
stages, and it is the one line whose recipe lives somewhere else: the formula is
in [QMdmm/homebrew-qmdmm](https://github.com/QMdmm/homebrew-qmdmm), and this
repository taps it instead of carrying a copy of its own. What stage A verifies
is therefore the recipe a user gets, and a second copy could only drift from it.

Three things are macOS's own:

* **A fresh runner is the clean container.** A macOS runner cannot run a Linux
  container, so `runs-on` is the machine, and the three jobs are a group of their
  own rather than rows of the matrix above — `runs-on` and `container:` are
  job-level keys and a row cannot differ from its neighbours in either. One
  difference from a container is asserted rather than assumed: a container starts
  out empty, while a runner image already carries Homebrew, cmake and ninja. Qt
  is the package that would make stage B vacuous, and it is not in the image.

* **There is no dev package.** One formula carries the programs, the headers and
  the CMake package together, the way Arch's single package does, so stage C
  asks not "does a second package resolve" but "is the one package enough to
  build against". With a consequence the Linux lines do not have: `brew link`
  puts a keg's `bin/` and `lib/` into the prefix but leaves `lib/cmake` inside
  the keg, so a consumer does not find the CMake package by itself and
  `build-verify-macos.sh` has to name the prefixes. It derives them rather than
  listing them — every dependency the formula pulled in contributes its prefix,
  which is what puts Qt's own sub-modules on the path without naming any of them.

* **The criterion is "it poured", not "it installed".** A formula whose bottle
  block disagrees with the bottle that was produced — a stale checksum, the file
  named in the two-hyphen spelling, a tag for a different macOS — quietly falls
  back to building from source. The stage would pass having verified nothing
  about the bottle at all, so the install log is required to show a pour *and* to
  show no source build.

The platform verification is `ci/runtime-verify-macos.sh` and the pair
`ci/build-verify-macos.sh` + `ci/run-verify-macos.sh` — one script per platform
rather than per face, as on Linux, and tools differ in five places with one
reading pointing the other way:

| Linux | macOS |
|---|---|
| `ldd`, which resolves references and reports `not found` | `otool -L`, which lists load commands and does not resolve them: it can only show where a reference points. Resolving is left to the programs actually running, whose loader says `Library not loaded` / `image not found` |
| the assertion is "nothing is unresolved" | on the `brew` face, built against Homebrew's Qt, every reference must point **into** `/opt/homebrew`; on the `dmg` face — the same `otool -L` reading with the opposite expectation — nothing may point outside the bundle and `/System` / `/usr/lib`. That is why the script takes a face (`MACOS_FACE`) rather than assuming one, and both faces are now in use |
| `/proc/net/tcp`, read for `0A` / `01` | `lsof -t -nP -iTCP:6366 -sTCP:LISTEN` / `-sTCP:ESTABLISHED`, which answers with a pid or with nothing |
| `timeout`, from coreutils or busybox | coreutils is not in the image, so the workflow installs it as a harness dependency, the way the Alpine line installs bash. The reading is `gtimeout` — GNU timeout, so the same `124` for "still running when the clock ran out"; the `g` prefix is what keeps it from shadowing the BSD tools that were already here |
| `strings -a -e l`, for a QML path Qt stores as UTF-16 | this platform's `strings` is the LLVM one and has no `-e` at all — asking for it is an error, not an empty result. The path is read by deleting the NULs of its UTF-16 encoding instead |

## The .dmg line

The second macOS line, and the one whose product is not a package at all: a
single universal `QMdmm-<version>-Darwin.dmg` holding a `QMdmm6.app` that carries
its own Qt, a symlink to `/Applications` to drag it onto, and a readme. It is the
install shape for a machine with no package manager in the picture — which is why
it is also the only line with **no stage C**.

Four things are this line's own:

* **Qt is handed to it by the workflow.** Every other line takes Qt from the
  platform: a distribution's packages, or the three Qt sub-modules the formula
  depends on. A
  bundle cannot — it has to be built against an archive whose frameworks can be
  copied into it, and Homebrew's Qt has QML plugins that are symlinks into the
  Cellar, which dangle the moment they are copied. So the job installs the
  official archive with `install-qt-action` and the stage reads `QT_ROOT_DIR` out
  of it. The patch is pinned to an exact version rather than a `6.11.*` range, for
  a measured reason: `aqtinstall`'s default hash algorithm is sha256, and Qt
  publishes a package's `.sha256` only some time after a release lands, so a run
  that floated onto a freshly published patch died with
  `ChecksumDownloadFailure` before it had downloaded anything.

* **One product for both architectures.** `CMAKE_OSX_ARCHITECTURES="x86_64;arm64"`
  produces a universal bundle instead of an architecture matrix. It is not a free
  choice: Homebrew ships no x86_64 macOS bottles any more, so this `.dmg` is the
  only route an Intel machine has left. The stage asserts it rather than trusting
  it — every Mach-O in the bundle has to be `x86_64 arm64`.

* **There is no stage C, and its absence is a criterion rather than a gap.**
  There is no dev package on macOS and the image carries no development content:
  `macdeployqt` copies a framework's binary and `Resources` and drops its
  `Headers`, so a bundle holds no `lib/cmake`, no `.pc` and no `.prl`. Where the
  other lines prove a consumer can build against the dev package, this one asserts
  that there is nothing to build against — the image's top level is exactly three
  entries, and a fourth would be content nobody decided to ship.

* **The criterion is "it is self-contained", not "it installed".** Stage B runs on
  a runner with no Qt at all — asserted before anything is copied — and the
  dependency assertion points the other way from the Homebrew line's: nothing may
  resolve outside the bundle and the system. A program that starts under those
  conditions can only have got its Qt out of the bundle.

Three scripts, two of them this line's own:

* `ci/pack-macos.sh` — stage A: fetch the ref, configure against the official Qt
  for both architectures, build, `cpack -G DragNDrop`, then assert the shape of
  the image on the **mounted** image: exactly three top-level entries, 18
  frameworks in the bundle, all three platform plugins with `libqoffscreen.dylib`
  among them, the ad-hoc signature verifying, and every Mach-O universal.
* `ci/runtime-macos.sh` — stage B's first half: assert the runner has no Qt, mount
  the image, and copy `QMdmm6.app` to `/Applications`, which is what the image's
  own readme tells a user to do. That the copy is what gets run matters here: the
  framework lookups live in the bundle's `Info.plist` and are only exercised by a
  copy that moved.
* `ci/runtime-verify-macos.sh` with `MACOS_FACE=dmg` — the verification the
  Homebrew line runs, with the programs read out of the bundle and the dependency
  assertion pointing the other way.

## Running it

Daily, on a schedule: the whole suite re-runs against `main` and `Release` — the
four containers and the macOS jobs — so a packaging regression surfaces within a
day rather than at the next release. The
`cron` field reads `0 0 * * *`, but the field is not when the runs start:
GitHub's scheduler has no timezone setting and launches scheduled runs hours
after the trigger it was given. That lateness is stable per cron value but not
derivable from it (four runs measured: 3h20m to 5h41m late), so the field is
treated as a dial that gets nudged when the drift shifts, not as a promise of a
clock time. The four runs are recorded in the note on the schedule in the
workflow.

A scheduled run has no inputs at all, so the ref and the build type come from
the `QMDMM_REF` / `QMDMM_BUILD_TYPE` defaults in `env` — which is also why those
two are `env` entries rather than `inputs` read directly at the point of use.

Manually:

```
gh workflow run packaging-smoke.yml -f qmdmm_ref=<branch|tag|full-sha>
gh run watch
```

Inputs (dispatched runs only):

* `qmdmm_ref` — the QMdmm ref to package and verify, given as a branch name, a
  tag name or a full 40-character commit SHA. The value goes straight into
  `git fetch --depth 1 origin '<ref>'`, which resolves ref names and complete
  object names and nothing else, so an abbreviated SHA is rejected at checkout
  in every job that fetches the source — an error that reads as a checkout
  failure rather than as the input it is. Defaults to `main`, which the
  packaging work (`packaging-consumer-support`) was merged into.
* `build_type` — CMake build type, default `Release`.

Images: `debian:sid`, `fedora:latest`, `archlinux:base` and `alpine:latest`
(the rolling pointers). Pinning per release and adding `fedora:rawhide` as a
non-blocking weekly run is left for a later pass, once the manual flow is stable.

The Homebrew line runs on `macos-latest` rather than on an image, which is also
why it is a job group of its own. Its row is the one packaging method whose
output is version-tagged by the machine it was built on: a bottle records the
producing runner's macOS version, which is its compatibility floor, so supporting
a second macOS would mean a second runner and a second row, not a second build on
this one. Both `qmdmm_ref` and `build_type` apply here as they do everywhere; the
build type does not reach the formula, which pins `Release` itself, exactly as
the Alpine line's recipe does.

## Qt version matrix

`qt-version-matrix.yml` asks a question the packaging stages cannot: QMdmm
declares `Qt ≥ 6.7`, but its own CI takes Qt from the distribution (6.10.2 on
Ubuntu 26.04), so every release between the declared floor and that one had gone
untested. The workflow builds QMdmm's own sources and runs `ctest` once per Qt
LTS that is both still supported and at or above the floor — **6.8 and 6.11**;
every other Qt 6 release has reached end of life — daily and on demand. 6.5 is
not in the matrix: its configure failure comes from Qt's own helper (qtbase
`721cfbd1`, picked to 6.7), so the floor was raised past it rather than worked
around.

It is a separate file rather than a fourth packaging stage, and it inherits
nothing from `packaging-smoke.yml`: its `cron` is declared in its own file rather
than assumed, and Qt comes from `install-qt-action`, because no runner image
supplies these versions — Ubuntu 24.04 ships Qt 6.4.2, below the floor, and 26.04
ships 6.10.2. The runners split the same way: 24.04 for 6.8, 26.04 for
6.11.

```
gh workflow run qt-version-matrix.yml -f qmdmm_ref=<branch|tag|full-sha>
```

The `qmdmm_ref` input defaults to `main`, as in the packaging workflow, and
takes the same forms: a branch name, a tag name or a full 40-character commit
SHA. `actions/checkout` classifies the value as a commit only when it is 40 or 64
hex characters, and otherwise treats it as a ref glob (`+refs/heads/<ref>*`), so
an abbreviated SHA fails here too. Only the failure differs: the action retries
the fetch three times with a backoff and reports it as a failed `git` invocation,
where the packaging workflow's own `git fetch` stops at the first attempt and
says which ref it could not find. The Qt version installed for a run is printed
in the job log, so a run records which patch release each line currently
resolves to.
