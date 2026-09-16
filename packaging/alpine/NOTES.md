# Alpine packaging recipe (qmdmm)

Verified end-to-end 2026-09-16. `abuild` built `qmdmm-0.0.1-r0.apk` plus `-dev` /
`-doc` in one pass (self-signed package *and* repository index). Dependency
metadata was then proven by *real resolution*: a second, pristine rootfs
(`apk add qmdmm qmdmm-dev qmdmm-doc`, no `--force` / `--nodeps`) pulled 103
packages from the local repo + upstream mirrors, rc=0. Afterwards ldd was clean
for all three binaries and the GUI survived a 20s offscreen timeout. Full
write-up with the pitfall table: `nemn9852/qmdmm-maintenance#20`.

## Files

- `APKBUILD` — the exact file used for the verified build (byte-for-byte).

## Source tarball

`source=` points to a local `qmdmm-0.0.1.tar.gz` (not committed here — this repo
keeps no binaries). Produce it from the QMdmm git tree, **not** a codeload download:

```bash
git clone https://github.com/Fsu0413/QMdmm && cd QMdmm
git archive --format=tar.gz --prefix=qmdmm-0.0.1/ d0f89c92a7299d6315c1c779584dfe52b21dc4d8 \
  -o qmdmm-0.0.1.tar.gz
# sha512: 9cf64de80234d42f969fdaebf762f9fe79980714725d99d94614a9de3f6ae09
#         998cbe150956bf54fc7977ba34472cc79282ab73d0d1ea73bc3831c603c2fdbce
```

Commit `d0f89c9` = `origin/main` at 2026-09-16. The prefix matters: abuild
expects the tarball to unpack to `$pkgname-$pkgver`. Put the tarball next to the
APKBUILD, then `abuild`. The `sha512sums` pin catches any regenerated tarball
that doesn't match (e.g. from a different git version or prefix).

## Environment facts (v3.24, x86_64)

- Base: Alpine **v3.24**, Qt **6.11.1-r0**, cmake 4.2.3, abuild 3.17.0-r0,
  gcc 15.2.0. If a container job bootstraps from a minirootfs tarball instead of
  an image tag, pin the version: `releases/x86_64/alpine-minirootfs-3.24.1-x86_64.tar.gz`
  — the `releases/latest/` path is **404** on every mirror tried.
- `lrelease` (Qt6 LinguistTools, needed by `qt6_add_translations`) ships in
  **qt6-qttools**: `/usr/bin/lrelease6` + `/usr/lib/qt6/bin/lrelease`. No
  separate `-dev` subpackage needed for it beyond `qt6-qttools-dev`.
- Toolchain to install before building: everything in `makedepends` plus
  `abuild fakeroot scanelf musl-utils` (the verified closure was 353 packages).

## Build notes

- **`abuild` refuses to run as root** (uid 0 without a fakeroot key aborts).
  Container jobs run every step as root, so create a non-root builder first:

  ```bash
  addgroup -g 100 abuild
  adduser -D -u 100 -G abuild -h /home/builder builder
  apk add --no-cache sudo
  printf '%s\n' '%wheel ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/wheel  # add builder to wheel
  su builder -c 'abuild-keygen -a -n && abuild -r'
  ```

  The sudo setup is what lets `abuild -r` auto-install `makedepends` (via
  `abuild-apk`); keep it, and **do not add `-d`**. (`-d` skips that dependency
  resolution entirely — it would silently delete the very thing CI must verify.
  The verified local run used `-d` only because its tooling couldn't execute
  the setuid `abuild-sudo` helper; that constraint does not exist in containers.
  The original host was a no-root Debian box driving the rootfs through a
  translation layer — the `-i 100:100` / `HOME=/root` / `-d` details in #20
  belong to *that* environment and must not be copied into a container recipe.)
- **`cmake -G "Unix Makefiles"` is deliberate.** Alpine's cmake defaults to
  Ninja, but its `ninja-build` package installs the binary to
  `/usr/lib/ninja-build/bin/ninja` — off PATH — so Ninja fails to find a make
  program. Correspondingly `make` is *not* in the default toolchain closure:
  keep it in `makedepends`.
- **Signing / repo layout.** `abuild -r` writes packages to
  `$HOME/packages/apk/x86_64/` and generates + signs `APKINDEX.tar.gz` there.
  A consuming `file://` repository line must point at the **parent** of
  `x86_64/` (apk appends `<arch>/APKINDEX.tar.gz` itself — pointing at the arch
  dir yields a `x86_64/x86_64/` not-found). To install into a clean container
  without `--allow-untrusted`, copy the **public** key
  (`~builder/.abuild/*.rsa.pub`) into its `/etc/apk/keys/`. The private key
  never leaves the build container; in CI keep it as a secret or generate
  per-run ephemeral ones.

## Packaging-shape notes (read before "fixing" anything)

- **`-dev` owning `/usr/lib/cmake/QMdmm6/*` is Alpine convention, not a bug.**
  abuild's default `split_dev` grabs the cmake config dir (7 files), headers
  and dev `.so` symlinks; the main package keeps none of them, and `-dev`
  auto-declares `depend = qmdmm=0.0.1-r0`. Consumers `find_package(QMdmm6)`
  after installing `-dev`. This differs from the CPack `dev6` layout on the
  deb/rpm lines — leave it.
- **`depends` needs only** `qt6-qtbase qt6-qtdeclarative qt6-qtwebsockets`.
  The offscreen platform plugin the smoke test uses (`libqoffscreen.so`) is
  owned by **qt6-qtbase-x11**, which `qt6-qtdeclarative` already depends on
  (verified with `apk info -W` / `apk info -r`) — no explicit entry needed.
  QML sources are compiled into the binary via `qt6_add_qml_module`, so there
  is no Debian-style `qml6-module-*` counterpart to add either. Runtime `so:`
  deps are completed automatically by scanelf; the three names above are the
  human-readable floor.
- `options="!check !debug"`: 0.0.1 keeps size sane (debug subpackages off), and
  `check()` was intentionally not wired (build ran with `BUILD_TESTING=OFF`).
  When adding it later: `-DBUILD_TESTING=ON` + `ctest` for `tst_qmdmm_smoke6`.

## Smoke criteria (Alpine-flavored)

- **busybox `timeout` returns 143** (128+SIGTERM) when it kills a still-living
  process — not GNU's 124. Treat `rc ∈ {0,124,143}` as survived, with a fatal
  guard: zero matches for
  `error while loading|version .* not found|Segmentation|Aborted` in stderr.
- `ldd` here is the musl-utils variant; same criterion — zero `not found` lines
  for `QMdmm6` / `QMdmmServer6` / `QMdmmBot6`.
- Run the heartbeat in one foreground window (killed background shells produced
  bogus 127/134 exit codes during verification).
- QML runtime warnings (`ReferenceError: game is not defined`, Connections
  signal mismatches) are known upstream noise — not packaging failures.
