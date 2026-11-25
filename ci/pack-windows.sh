#!/usr/bin/env bash
#
# Stage A for the Windows line, in one file: fetch QMdmm at the requested ref,
# configure for MSVC against the Qt the workflow installed, build, pack a ZIP of
# the installed tree with cpack, then read the archive back.
#
# It is the same stage as the other lines with the same skeleton - fetch the ref,
# configure against a pinned install prefix, build, pack, collect - and only
# these differ:
#
#   the product is the archive, not a package beside it
#     The machines this line serves have no package manager that could install a
#     package, and there is no repository here to publish one to. So the ZIP of
#     the installed tree is the whole deliverable, and it is asked for by name
#     rather than added next to a native generator. That is also why this file
#     has no `PACK_ARCHIVE` switch: the flag exists to keep a release from
#     carrying an archive, and this line has one caller - the daily run. A
#     release that starts publishing this line decides that then.
#
#   the stage is the only one
#     Stage B asks whether the runtime installs and runs on a clean machine, and
#     stage C whether a consumer builds against the dev package. On a Windows
#     runner the machine that would answer either is the machine that just built
#     the tree, toolchain and Qt included, so the answer would describe the runner
#     rather than the product. What this file asserts instead is the shape of what
#     came out, which is the half a run can answer.
#
#   nothing is deployed into it
#     No Qt, no plugins, no runtime DLLs of anyone else's: this is the installed
#     tree as cpack lays it down, the same statement the Linux TGZ makes. Only the
#     .dmg line carries Qt inside its product, because a bundle is the shape that
#     needs to. A machine that unpacks this needs Qt 6.8 or newer of its own, the
#     way a machine that unpacks a Linux TGZ needs its distribution's Qt.
#
#   the Qt it builds against, and the generator
#     The workflow installs the official archive with install-qt-action and hands
#     its root down as QT_ROOT_DIR - the same hand-off as the .dmg line, for the
#     same reason: a distribution does not package Qt for MSVC here. There is no
#     `-G`: the default generator on a windows-latest runner is the Visual Studio
#     one, and naming a version would be one more literal to revisit when the
#     image moves. That generator is multi-config, so the build type is chosen on
#     the build and pack commands and a `-DCMAKE_BUILD_TYPE` at configure time
#     would be ignored - hence none.
set -euxo pipefail

git init qmdmm-src
git -C qmdmm-src remote add origin "$QMDMM_REPO"
git -C qmdmm-src fetch --depth 1 origin "$QMDMM_REF"
git -C qmdmm-src checkout --detach FETCH_HEAD
echo "QMdmm HEAD: $(git -C qmdmm-src log --oneline -1)"

# QT_ROOT_DIR comes from install-qt-action's set-env, and it is asserted rather
# than assumed: an empty prefix would turn CMAKE_PREFIX_PATH into a search for Qt
# anywhere, and the build would then fail somewhere less legible than here.
if [ -z "${QT_ROOT_DIR:-}" ]; then
  echo "::error::QT_ROOT_DIR is not set; the install-qt-action step is what provides it"
  exit 1
fi
echo "official Qt at $QT_ROOT_DIR"

# The install prefix is inside the workspace rather than left at CMake's default
# of `C:/Program Files/QMdmm`. The prefix is what the archive is built out of and
# what CPack stages the install into, so pointing it at a directory this job owns
# keeps both inside the workspace, where the reading below can reach them.
#
# `-A x64` matches the architecture of the Qt archive installed above. BUILD_TESTING
# is off as on every other stage-A line: the tree's own CI is where the tests run.
cmake -S qmdmm-src -B build -A x64 \
  -DCMAKE_INSTALL_PREFIX="$PWD/inst" \
  -DCMAKE_PREFIX_PATH="$QT_ROOT_DIR" \
  -DBUILD_TESTING=OFF \
  -DQMDMM_EXPORT_PRIVATE=NO
cmake --build build --config "$QMDMM_BUILD_TYPE" --parallel

# The tree's own CPACK_GENERATOR also holds 7Z, TGZ, TXZ and TZST on every
# platform. They are not asked for: one format is the product, not five. The
# config is named because the generator is multi-config - without it cpack would
# install a configuration that was never built.
(cd build && cpack -C "$QMDMM_BUILD_TYPE" -G ZIP)

mkdir -p out-archive
cp -v build/*.zip out-archive/
archive=$(ls out-archive/*.zip | head -1)
test -n "$archive"

# What the archive holds, read out of the archive rather than off the build tree,
# so that what is measured is what a machine would unpack. The names are the
# installed ones and not the build ones: the programs carry the module suffix the
# rest of the project installs them under, and the shared libraries there are
# QMdmm's own - Qt's are absent on purpose (see the header). `include/` and
# `lib/cmake/` are asserted because they are what makes this the same install
# shape the Linux TGZ carries: cpack's ZIP generator has no components, so the
# whole tree is in one file, development content included. Saying so is the point
# - a Windows user gets the headers and the CMake package in the same archive.
#
# python is the reading tool rather than an extracted copy plus `find`: it is
# present on the runner, it reads the ZIP without unpacking anything, and it can
# say which entry is missing instead of only that something is.
python - "$archive" <<'PY'
import sys
import zipfile

archive = sys.argv[1]
with zipfile.ZipFile(archive) as z:
    names = [n for n in z.namelist() if not n.endswith('/')]

if not names:
    sys.exit(f'::error::{archive} holds no files')

def has(suffix):
    return any(n == suffix or n.endswith('/' + suffix) for n in names)

def has_fragment(fragment):
    return any(fragment in n for n in names)

failed = 0

# The programs, by the names the tree installs them under.
for exe in ('QMdmm6.exe', 'QMdmmServer6.exe', 'QMdmmBot6.exe', 'QMdmmCtl6.exe'):
    if not has('bin/' + exe):
        print(f'::error::bin/{exe} is not in the archive')
        failed = 1

# QMdmm's own shared libraries, which are the only libraries in it.
for lib in ('QMdmmCore6.dll', 'QMdmmNetworking6.dll'):
    if not has('bin/' + lib):
        print(f'::error::bin/{lib} is not in the archive')
        failed = 1

for fragment, what in (('include/QMdmmCore/', 'the Core headers'),
                       ('lib/cmake/QMdmm6/', 'the CMake package')):
    if not has_fragment(fragment):
        print(f'::error::{fragment} is missing; {what} did not get installed')
        failed = 1

# An archive carries the tree, not the machine it was built on. A leading slash or
# a drive letter would mean the install prefix leaked into the entries, and
# unpacking it would then write to a path nobody chose.
leaked = [n for n in names if n.startswith('/') or ':' in n]
if leaked:
    print('::error::these entries carry an absolute path:')
    for n in leaked[:10]:
        print('  ' + n)
    failed = 1

roots = sorted({n.split('/')[0] for n in names})
print('### the archive')
print()
print(f'`{archive}`: {len(names)} files')
print()
print('```')
print('\n'.join(roots))
print('```')
sys.exit(1 if failed else 0)
PY

printf '### The archive produced\n\n' >> "$GITHUB_STEP_SUMMARY"
printf '```\n' >> "$GITHUB_STEP_SUMMARY"
printf 'archive\tversion\tfile\n' >> "$GITHUB_STEP_SUMMARY"
printf 'windows\t%s\t%s\n' \
  "$(awk '/^project\(/ { in_project = 1 } in_project && /VERSION/ { sub(/.*VERSION[ \t]+/, ""); sub(/[ \t].*/, ""); print; exit }' qmdmm-src/CMakeLists.txt)" \
  "$(basename "$archive")" >> "$GITHUB_STEP_SUMMARY"
printf '```\n\n' >> "$GITHUB_STEP_SUMMARY"
{
  echo 'The installed tree as one ZIP, built with cpack. It carries no Qt and'
  echo 'no one else'\''s runtime libraries, the same statement the Linux TGZ'
  echo 'makes: only the .dmg line bundles Qt into its product. A machine that'
  echo 'unpacks this needs Qt 6.8 or newer of its own.'
} >> "$GITHUB_STEP_SUMMARY"
