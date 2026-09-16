# Alpine packaging recipe (qmdmm)

Proven end-to-end on 2026-09-16: `abuild -d -r` built `qmdmm-0.0.1-r0.apk` plus
`-dev` / `-doc` in one pass (self-signed, repository index generated); a *second,
pristine* rootfs then resolved real dependencies on `apk add qmdmm qmdmm-dev
qmdmm-doc` — 103 packages, rc=0, no `--force` / `--nodeps`; ldd clean for all
three binaries; offscreen smoke survived the 20s timeout. Full write-up with the
pitfall table: `nemn9852/qmdmm-maintenance#20` (private ledger repo).

Environment facts: Alpine **v3.24** (minirootfs 3.24.1 — pin it, `releases/latest/`
is 404), Qt **6.11.1-r0** (`lrelease` ships in `qt6-qttools`), cmake 4.2.3,
abuild 3.17.0-r0, gcc 15.2.0.

## Entrypoints

Both wrappers run the build in a proot virtual root over `$HOME/alpine-rootfs`
(Debian host, zero root). They need proot 5.4 with `PROOT_NO_SECCOMP=1` —
without it the fake-uid mapping is inert.

- `proot-entrypoint-root.sh` — fake uid **0** (`proot -S`), the identity for
  `apk add` into the build rootfs.
- `proot-entrypoint-abuild.sh` — fake uid **100:100**, the identity for `abuild`:
  abuild refuses to run as uid 0 without a fakeroot key, and proot's `-i` / `-0` /
  `-S` flags share one slot (last wins), so faking uid 100 means dropping `-S`
  and binding `/dev` `/proc` `/sys` `/tmp` explicitly.

Both `env HOME=/root` — otherwise the host `~/.abuild` is bind-mounted over the
guest's and shadows the generated signing keys.

## Build flow

1. Unpack pinned minirootfs → `~/alpine-rootfs`; point repositories at a v3.24
   mirror; write `/etc/resolv.conf` by hand (minirootfs ships none, proot won't
   bind it).
2. `apk add` toolchain once: everything in `makedepends` plus `abuild fakeroot
   scanelf musl-utils` (353 packages total, see #20).
3. `abuild-keygen -a -n`, then `abuild checksum` (via the abuild entrypoint).
4. `abuild -d -r` — **`-d` is mandatory under proot**: dependency auto-install
   goes through `abuild-sudo`, a setuid binary, and proot does not emulate
   setuid.
5. Serve results as `file://…/root/packages/apk` (the **parent** of `x86_64/`;
   apk appends `<arch>/APKINDEX.tar.gz` itself) from a second clean rootfs and
   drop the `.rsa.pub` into its `/etc/apk/keys` — private keys never leave the
   build box.

## Alpine-specific choices worth knowing

- `cmake -G "Unix Makefiles"`: Alpine's cmake defaults to Ninja, but its
  `ninja-build` ships `/usr/lib/ninja-build/bin/ninja` — off PATH; and `make`
  is *not* in the default toolchain closure, hence listed in `makedepends`.
- `-dev` takes `/usr/lib/cmake/QMdmm6/*` via abuild's path-pattern split
  (Alpine convention — consumers `find_package(QMdmm6)` after installing
  `-dev`). This differs from the CPack `dev6` layout on the deb/rpm lines; it is
  correct here, don't "fix" it.
- `depends` names only `qt6-qtbase qt6-qtdeclarative qt6-qtwebsockets`: the
  offscreen platform plugin (`libqoffscreen.so`) is owned by `qt6-qtbase-x11`,
  which `qt6-qtdeclarative` already pulls — no explicit entry needed.
- Smoke gate: busybox `timeout` returns **143** (128+SIGTERM), not GNU's 124,
  when it kills a still-living process. Survival criterion must accept
  `rc ∈ {0,124,143}` with a fatal-pattern guard
  (`error while loading|version .* not found|Segmentation|Aborted` = 0).
