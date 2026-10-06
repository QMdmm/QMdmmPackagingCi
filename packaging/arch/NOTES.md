# Arch packaging recipe (qmdmm-6)

Verified end-to-end 2026-09-16. `makepkg` built `qmdmm-6-0.0.1-1-x86_64.pkg.tar.zst`
in one pass. Dependency metadata was then proven by *real resolution*: `qt6-websockets`
was removed from the system, and a plain `pacman -U` of the local package (no
`--nodeps`/`--force`) resolved and reinstalled it from the repo alongside `qmdmm-6`.
Afterwards ldd was clean for all three binaries, the GUI survived a 20s offscreen
timeout, and the in-repo `smoke` test exited 0. This recipe later became the Arch
line of `.github/workflows/packaging-smoke.yml`.

Single-package form (`qmdmm-6`, no split `-dev`) per Fs's call:
headers and `/usr/lib/cmake/QMdmm6/QMdmm6Config.cmake` ship in the main package.
Arch has no component-split mechanism like CPack's, so this is the natural shape there.

## Files

- `PKGBUILD` — the file used for the verified build, with one change made
  afterwards: `qt6-tools` and `cmake` moved into `depends` (see "Dependencies").
  Nothing else was touched.
- `.SRCINFO` — generated with `makepkg --printsrcinfo`, not hand-written. It
  restates `pkgver` and the tarball's name, so bumping the recipe means
  regenerating this too; `release/assert-release-version.sh` is what fails a
  release in which the two disagree.

## Dependencies

One package has to answer both questions, so `depends` is the union of what the
other two lines' runtime package and dev package declare, translated to Arch
names — there is no second package to carry the other half:

| what | Debian | Arch |
|---|---|---|
| runtime | `libqt6core6` … `qml6-module-qtquick` | `qt6-base`, `qt6-declarative`, `qt6-websockets` |
| dev | `qt6-base-dev`, `qt6-declarative-dev`, `qt6-websockets-dev`, `qt6-tools-dev`, `cmake` | the same three packages (Arch keeps a module's development files in them), plus `qt6-tools` and `cmake` |

`qt6-tools` is not optional here: `QMdmmGui/CMakeLists.txt` calls
`find_package(Qt6 REQUIRED COMPONENTS Widgets LinguistTools)` and
`qt6_add_translations()`, so a consumer holding this package's CMake config cannot
build the GUI without it. It lived in `makedepends` only, which was enough for the
local run — that build environment had it — and not enough for a clean install.
`cmake` moved for the same reason, taken from the same list on the other lines.

## Source tarball

`source=` points to a local `qmdmm-6-0.0.2.tar.gz` (not committed here — this repo
keeps no binaries). Produce it from the QMdmm git tree, **not** a codeload download:

```bash
git clone https://github.com/QMdmm/QMdmm && cd QMdmm
git archive --format=tar.gz --prefix=qmdmm-6-0.0.2/ 0.0.2 \
  -o qmdmm-6-0.0.2.tar.gz
# sha256: 1991ccbd908656854bd03fc1fe91c9d21a1a0c50838044fbe06cf8d086ab89f2
```

`0.0.2` is the tag the recipe names, and the hash is the archive of that tag —
the same `git archive` command a run performs. Put the tarball next to the
PKGBUILD, then `makepkg -f`. The PKGBUILD's `sha256sums` pins the hash, so a
regenerated tarball that doesn't match is caught at validation.

That is not the same claim as the one at the top of this file. The build measured
end to end on 2026-09-16 was 0.0.1's, from `d0f89c9` = `origin/main` at that date;
this pin is the release tag's archive and has not itself been built here.

In CI the tarball is produced the same way but from whatever ref the run was
handed, and `updpkgsums` refreshes the recipe's checksums before `makepkg` runs:
the committed hash above pins the archive of this recipe's own version, which is
not what a later run packages. The other half of that is
`release/assert-release-version.sh`: `pkgver` in this file is a number no other
stage reads, so a release dispatched for one version and a recipe left saying
another would stamp packages with the wrong one and stay green throughout. That
guard refuses it, and syncing this file is what clears the refusal.

## Build notes

- `makepkg` **refuses to run as root**. GitHub Actions container jobs execute every
  step as root, so a CI recipe must create a non-root user and run the build as it,
  e.g.:

  ```bash
  useradd -m -G wheel builder
  pacman -S --noconfirm --needed sudo
  printf '%%wheel ALL=(ALL) NOPASSWD: ALL\n' > /etc/sudoers.d/wheel
  install -o builder -g builder -m 644 PKGBUILD .SRCINFO /home/builder/pkg/
  install -o builder -g builder -m 644 qmdmm-6-0.0.2.tar.gz /home/builder/pkg/
  su builder -c 'cd ~/pkg && makepkg -f --noconfirm'
  ```

  Package *installation* (stage B style, `pacman -U`) goes back to root — that is fine.
- Runtime deps: `qt6-base` (Core/Gui/Network/WebSockets/Widgets), `qt6-declarative`
  (Qml/Quick/QuickWidgets — Arch keeps QML runtime modules inside it, there is no
  `qml6-module-*` split like Debian's), `qt6-websockets`. Make deps: `cmake`, `ninja`,
  `qt6-tools` (provides `Qt6LinguistTools` / `lrelease`). Each package's file→name
  mapping must be verified in the target distro, not copied from another line's list.
- `options=(!debug !lto)` overrides Arch defaults (both are on by default).
- `check()` is intentionally absent, and the CI does not ask for one. This recipe
  is the Arch line of `.github/workflows/packaging-smoke.yml`, whose pack stage is
  pack-only on every line — Debian and Fedora pack with `BUILD_TESTING=OFF` too —
  so an Arch-only `check()` would make the three lines answer different questions.
  Test execution stays where it already is: QMdmm's own CI and the Qt version
  matrix. The verified run configured with makepkg defaults (`BUILD_TESTING`
  off), so `ctest` had nothing registered even then.
