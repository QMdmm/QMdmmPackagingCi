# Arch packaging recipe (qmdmm-6)

Verified end-to-end 2026-09-16. `makepkg` built `qmdmm-6-0.0.1-1-x86_64.pkg.tar.zst`
in one pass. Dependency metadata was then proven by *real resolution*: `qt6-websockets`
was removed from the system, and a plain `pacman -U` of the local package (no
`--nodeps`/`--force`) resolved and reinstalled it from the repo alongside `qmdmm-6`.
Afterwards ldd was clean for all three binaries, the GUI survived a 20s offscreen
timeout, and the in-repo `smoke` test exited 0. Full write-up with pitfalls:
`nemn9852/qmdmm-maintenance#19`.

Single-package form (`qmdmm-6`, version `0.0.1`, no split `-dev`) per Fs's call:
headers and `/usr/lib/cmake/QMdmm6/QMdmm6Config.cmake` ship in the main package.
Arch has no component-split mechanism like CPack's, so this is the natural shape there.

## Files

- `PKGBUILD` — the exact file used for the verified build (byte-for-byte).
- `.SRCINFO` — generated with `makepkg --printsrcinfo`, not hand-written.

## Source tarball

`source=` points to a local `qmdmm-6-0.0.1.tar.gz` (not committed here — this repo
keeps no binaries). Produce it from the QMdmm git tree, **not** a codeload download:

```bash
git clone https://github.com/QMdmm/QMdmm && cd QMdmm
git archive --format=tar.gz --prefix=qmdmm-6-0.0.1/ d0f89c92a7299d6315c1c779584dfe52b21dc4d8 \
  -o qmdmm-6-0.0.1.tar.gz
# sha256: 355e0cba7d4b8b33c93e2418b36f9af3a3144d8e7d4b24adba8d317db56a91b5
```

Commit `d0f89c9` = `origin/main` at 2026-09-16. Put the tarball next to the PKGBUILD,
then `makepkg -f`. The PKGBUILD's `sha256sums` pins the hash, so a regenerated tarball
that doesn't match is caught at validation.

## Build notes

- `makepkg` **refuses to run as root**. GitHub Actions container jobs execute every
  step as root, so a CI recipe must create a non-root user and run the build as it,
  e.g.:

  ```bash
  useradd -m -G wheel builder
  pacman -S --noconfirm --needed sudo
  printf '%%wheel ALL=(ALL) NOPASSWD: ALL\n' > /etc/sudoers.d/wheel
  install -o builder -g builder -m 644 PKGBUILD .SRCINFO /home/builder/pkg/
  install -o builder -g builder -m 644 qmdmm-6-0.0.1.tar.gz /home/builder/pkg/
  su builder -c 'cd ~/pkg && makepkg -f --noconfirm'
  ```

  Package *installation* (stage B style, `pacman -U`) goes back to root — that is fine.
- Runtime deps: `qt6-base` (Core/Gui/Network/WebSockets/Widgets), `qt6-declarative`
  (Qml/Quick/QuickWidgets — Arch keeps QML runtime modules inside it, there is no
  `qml6-module-*` split like Debian's), `qt6-websockets`. Make deps: `cmake`, `ninja`,
  `qt6-tools` (provides `Qt6LinguistTools` / `lrelease`). Each package's file→name
  mapping must be verified in the target distro, not copied from another line's list.
- `options=(!debug !lto)` overrides Arch defaults (both are on by default).
- `check()` is intentionally absent: the verified run configured with makepkg defaults
  (`BUILD_TESTING` off), so `ctest` had nothing registered. When wiring into CI, pass
  `-DBUILD_TESTING=ON` and add a `check()` that runs `tst_qmdmm_smoke6` via ctest.
