# QMdmm's Homebrew formula. This is the one authoritative copy: the packaging
# harness (QMdmmPackagingCi) taps this repository rather than carrying a second
# copy, so what a user installs and what the harness verifies is the same
# recipe.
#
# The bottle block below is written by the release line rather than by hand:
# stage A bottles the tag on each macOS the release supports, and
# `release/publish-tap.sh` merges their checksums into this file and pushes it
# here - so this repository learns about a bottle when a release is cut, and not
# before. A bottle records one exact build on one exact macOS version, and the
# block carries one line per version: an install on a macOS the block names
# pours that bottle, and anywhere else falls back to the source tarball the
# urls below describe.
#
# When the harness packages a ref that is not a tag - which is what the daily
# run does, since it packages `main` - it rewrites `url`, `sha256` and
# `version` in the copy it tapped. A branch or a commit has no tag tarball, so
# the url becomes .../archive/<full-sha>.tar.gz and the version, normally
# detected from the url, has to be read out of the source tree and stated
# instead. The values committed here pin the tag that was verified locally: tag
# 0.0.1, whose tarball hashes to the sha256 below (measured three times, once
# through codeload directly).
#
# `QMDMM_MACOS_APP_BUNDLE` picks the install shape, and `OFF` - which is also
# what it defaults to - is the one a bottle can be built from: the three
# programs land in `bin/` as siblings with Qt provided by the machine. Turned
# on, the install produces a self-contained `QMdmm6.app` with Qt's frameworks,
# plugins and QML modules copied inside it instead - that is the `.dmg`'s shape,
# and it cannot be bottled because a bottle relocates a prefix rather than an
# application bundle. Measured locally: the flat shape against Homebrew's Qt
# gives all three programs an LC_RPATH that resolves Qt out of the Homebrew
# prefix plus the install prefix's own `lib`, and all three start.
#
# The Qt dependencies are the three sub-modules QMdmm links against, and not
# `qt`. That meta formula exists to install every Qt sub-module Homebrew ships -
# 39 of them, including qtwebengine, which is 111 MiB of bottle on its own - and
# a QMdmm install has no use for the other 36. The three are what a walk of
# `otool -L` from all three programs to a fixed point reaches, against
# Homebrew's Qt 6.11.2: qtbase (Core, Network, Gui, Widgets), qtdeclarative
# (Qml, Quick, QuickWidgets) and qtwebsockets (QMdmmNetworking). `qtsvg` arrives
# with qtdeclarative; CMake's own package files for all of them are found in the
# Homebrew prefix, where linking the kegs puts them, so the build needs no
# prefix path of its own.
#
# `qttools` is a build dependency: QMdmmGui's CMakeLists.txt asks for
# LinguistTools, and `qt6_add_translations` runs lupdate and lrelease while
# building. Other modules can be added the day something links them, which is
# what makes this list a reading rather than a guess.
#
# None of this pins a Qt version - Homebrew keeps one version of each formula -
# so the Qt 6.7 floor the project declares cannot be expressed here and the
# bottle floats with whatever the tap's Qt currently is.
class Qmdmm < Formula
  desc "Multiplayer card game server, bots and client"
  homepage "https://github.com/QMdmm/QMdmm"
  url "https://github.com/QMdmm/QMdmm/archive/refs/tags/0.0.2.tar.gz"
  sha256 "13c8b74dd6ea8cf3b7985230a6e97a733fa48aa6b7ef4734ad1c140ce2a62732"
  license "AGPL-3.0-or-later"
  head "https://github.com/QMdmm/QMdmm.git", branch: "main"

  bottle do
    root_url "https://qmdmm.github.io/QMdmmPackagingCi/brew"
    sha256 cellar: :any, arm64_golden_gate: "02a1a33f58f85deecd3ba9f5a9dad3378592c01ea148780ac3d5c210adbf2227"
    sha256 cellar: :any, arm64_tahoe:       "ad16fc593fbf23808bfed19b353b8f39bee6a336d4aa9263dd3db193d92f7998"
    sha256 cellar: :any, arm64_sequoia:     "f2bc8a5dcfb1de32bbbc504ca26ef95909303a291ffe23b190224e941761f4f5"
  end

  depends_on "cmake" => :build
  depends_on "ninja" => :build
  depends_on "qttools" => :build
  depends_on "qtbase"
  depends_on "qtdeclarative"
  depends_on "qtwebsockets"

  def install
    system "cmake", "-S", ".", "-B", "build", *std_cmake_args,
           "-G", "Ninja",
           "-DQMDMM_MACOS_APP_BUNDLE=OFF"
    system "cmake", "--build", "build"
    system "cmake", "--install", "build"
  end

  # The server's `--help` is the cheapest program the package ships that cannot
  # be started by accident: it prints its help text and calls std::exit(0)
  # before it reads any configuration or binds a socket (QMdmmServer/src/
  # config.cpp: `if (parser.isSet("h")) { std::cout << helpText(); std::exit(0); }`).
  # The GUI and the Bot would have to be started and then killed, which is what
  # the harness stages do anyway.
  #
  # This block is run, too. An install does not execute it, so the packaging
  # harness's Homebrew stage calls `brew test` on the copy it pours, and then
  # calls it once more against a copy of the block below whose program is not
  # installed - so the stage's reading is one that can go red. Rewriting this
  # block to name something else therefore means updating that mutation with it.
  test do
    system bin/"QMdmmServer6", "--help"
  end
end
