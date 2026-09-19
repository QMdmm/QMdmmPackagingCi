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

Stage A is one job per way of packaging: cpack handles Debian and Fedora and
makepkg handles Arch inside one shared job, while Alpine has a job of its own for
abuild. Stages B and C are matrix rows covering all four lines. The questions are
therefore asked once per distribution, and a difference between distributions
lives in the branch of a step rather than in a copy of it.

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
* `qt6_standard_project_setup(REQUIRES 6.5)`, mirroring QMdmm's own root

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

Alpine differs from the other three in two ways, one structural and one
load-bearing: its pack stage is a job of its own (`pack-alpine`), and the
repository stages B and C install from is signed.


Signing is not optional on Alpine: abuild calls `abuild-sign` for the packages and
for the repository index unconditionally and dies without a key. This repository
holds one half of a key pair and the repository settings hold the other.

* `packaging/alpine/neve-6aaaace6.rsa.pub` — the public half, copied into the
  consuming container's `/etc/apk/keys/` by stages B and C.
* the `PACKAGER_PRIVKEY` secret — the private half, written to
  `~builder/.abuild/neve-6aaaace6.rsa` in stage A, and nowhere else.

The two file names have to agree: abuild derives each signature's file name from
the private key's own file name and apk resolves that name in `/etc/apk/keys`, so
a signature made with a differently named key is untrusted by construction. Stage
A asserts the two halves are the same pair before it builds anything, which turns
a mismatch into one clear message rather than an `UNTRUSTED signature` two stages
later.

The key is long-lived on purpose. The line could generate a throwaway key per run,
as the local verification did, but then the public half committed here would mean
nothing and no one could ever check a published package against it.

## Running it

Daily, on a schedule: the whole suite re-runs against `main` and `Release`, so a
packaging regression surfaces within a day rather than at the next release. The
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
gh workflow run packaging-smoke.yml -f qmdmm_ref=<branch|tag|commit>
gh run watch
```

Inputs (dispatched runs only):

* `qmdmm_ref` — the QMdmm ref to package and verify. Defaults to `main`, which
  the packaging work (`packaging-consumer-support`) was merged into.
* `build_type` — CMake build type, default `Release`.

Images: `debian:sid`, `fedora:latest`, `archlinux:base` and `alpine:latest`
(the rolling pointers). Pinning per release and adding `fedora:rawhide` as a
non-blocking weekly run is left for a later pass, once the manual flow is stable.

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
gh workflow run qt-version-matrix.yml -f qmdmm_ref=<branch|tag|commit>
```

The `qmdmm_ref` input defaults to `main`, as in the packaging workflow. The Qt
version installed for a run is printed in the job log, so a run records which
patch release each line currently resolves to.
