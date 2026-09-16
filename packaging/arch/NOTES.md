# Arch packaging recipe (qmdmm-6)

Proven end-to-end on 2026-09-16: `makepkg` built `qmdmm-6-0.0.1-1-x86_64.pkg.tar.zst`
in one pass; `pacman -U` resolved real dependencies (qt6-websockets had been removed
first, and pacman pulled it back from the repo with no `--nodeps`/`--force`);
ldd clean for all three binaries; offscreen smoke survived the 20s timeout; in-repo
`smoke` test exited 0. Full write-up with pitfalls: `nemn9852/qmdmm-maintenance#19`.

Single-package form (`qmdmm-6`, version `0.0.1`, no split `-dev`) per Fs's call:
headers and `/usr/lib/cmake/QMdmm6/QMdmm6Config.cmake` ship in the main package.
Arch has no component-split mechanism like CPack's, so this is the natural shape there.

## Files

- `PKGBUILD` — the exact file used for the verified build (byte-for-byte).
- `.SRCINFO` — generated with `makepkg --printsrcinfo`, not hand-written.
- `archroot` — proot entry wrapper, only needed on a **rootless host** (e.g. running
  the Arch build inside a Debian user account). On a real Arch box, skip it.

## Source tarball

`source=` points to a local `qmdmm-6-0.0.1.tar.gz` (not committed here — this repo
keeps no binaries). It is produced from the QMdmm git tree, **not** a codeload
download:

```bash
git clone https://github.com/Fsu0413/QMdmm && cd QMdmm
git archive --format=tar.gz --prefix=qmdmm-6-0.0.1/ d0f89c92a7299d6315c1c779584dfe52b21dc4d8 \
  -o qmdmm-6-0.0.1.tar.gz
# sha256: 355e0cba7d4b8b33c93e2418b36f9af3a3144d8e7d4b24adba8d317db56a91b5
```

Commit `d0f89c9` = `origin/main` at 2026-09-16. Put the tarball next to the PKGBUILD,
then `makepkg -f`.

## Build notes

- `makepkg` **refuses to run as root**. On any host/container that defaults to root
  (GitHub Actions container jobs included), create a non-root user and `su` into it.
- Rootless proot route: bootstrap `archlinux-bootstrap-2026.09.01-x86_64.tar.zst`
  from `geo.mirror.pkgbuild.com/images/latest/` into a directory, then use
  `archroot -u … makepkg -f --noconfirm`. Two wrapper quirks matter:
  pseudo-root mode (`-S`) binds host `/etc` + `$HOME` into the guest, which can
  hijack `makepkg.conf`, so builds use the `-u` mode with **explicit** binds
  (`/dev /proc /sys` + build dir only, `HOME` pinned to the guest user); and set
  `LANG=C.UTF8` so the host locale never leaks into pacman tooling.
- `check()` is intentionally absent here: the verified run configured with makepkg
  defaults (`BUILD_TESTING` off), so `ctest` had nothing registered. If you wire this
  into CI, pass `-DBUILD_TESTING=ON` and add a `check()` target running
  `tst_qmdmm_smoke6` (see #19 "CI 化方案").
