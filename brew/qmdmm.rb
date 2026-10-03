# QMdmm's Homebrew formula. This is the one authoritative copy: the packaging
# harness (QMdmmPackagingCi) taps this repository rather than carrying a second
# copy, so what a user installs and what the harness verifies is the same
# recipe.
#
# There is no bottle block here. `brew bottle --merge --write` adds one, and
# the harness adds it to its own working copy inside the tap directory - never
# to this file, because a bottle records one exact build on one exact macOS
# version and this repository should only learn about one when a release is
# cut. A user installing today therefore builds from source, which is what the
# urls below describe.
#
# When the harness packages a ref that is not a tag - which is what the daily
# run does, since it packages `main` - it rewrites `url`, `sha256` and
# `version` in that working copy. A branch or a commit has no tag tarball, so
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
  url "https://github.com/QMdmm/QMdmm/archive/refs/tags/0.0.1.tar.gz"
  sha256 "2fe4085ca4ccd179f04321bfa4317a47f81cd6eb470d3a791db06b5b9f5a60d5"
  license "AGPL-3.0-or-later"
  head "https://github.com/QMdmm/QMdmm.git", branch: "main"

  bottle do
    root_url "https://qmdmm.github.io/QMdmmPackagingCi/brew"
    sha256 cellar: :any, arm64_tahoe: "abc5a50ed39dad022b8fb8f402bd511d8a28337c031ffed148b651d9347b495b"
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
