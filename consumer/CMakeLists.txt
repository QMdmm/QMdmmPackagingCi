# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Acceptance harness for the *installed* QMdmm dev package.
#
# Nothing in this project reaches into the QMdmm build tree for headers,
# libraries or targets. The only thing it takes from the source tree is the GUI
# and Bot sources themselves, so that "the dev package can build the GUI and the
# Bot" is tested for real instead of being approximated by a toy program.
#
# Configure it with:
#
#   cmake -S consumer -B build -G Ninja \
#       -DQMDMM_SOURCE_DIR=<checkout of Fsu0413/QMdmm>

cmake_minimum_required(VERSION 3.19)

project(QMdmmConsumer LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED true)

if (NOT DEFINED QMDMM_SOURCE_DIR)
    message(FATAL_ERROR "Pass -DQMDMM_SOURCE_DIR=<checkout of Fsu0413/QMdmm>")
endif()

# ---------------------------------------------------------------------------
# 1. The point of the exercise: the installed QMdmm 6 dev package.
# ---------------------------------------------------------------------------
# The version is the QMdmm product version; the "6" is the Qt generation, which
# is what the package directory and the QMdmm6:: namespace encode.
find_package(QMdmm6 0.0.1 REQUIRED COMPONENTS Core Networking)

message(STATUS "QMdmm6_VERSION=${QMdmm6_VERSION} QT_GENERATION=${QMdmm6_QT_GENERATION}")

# ---------------------------------------------------------------------------
# 2. A tiny program that only uses public headers and the imported targets.
# ---------------------------------------------------------------------------
# Exercises both spellings: the bare <QMdmmPlayer> and the prefixed
# <QMdmmCore/QMdmmPlayer>, plus the QMdmm6:: namespace and the generation-free
# QMdmm:: alias. Compiling is the assertion; running it is a bonus.
add_executable(qmdmm_consumer_api api-smoke.cpp)
target_link_libraries(qmdmm_consumer_api PRIVATE
    QMdmm6::Networking
    QMdmm6::Core
)

add_executable(qmdmm_consumer_api_versionless api-smoke.cpp)
target_link_libraries(qmdmm_consumer_api_versionless PRIVATE
    QMdmm::Networking
    QMdmm::Core
)

# ---------------------------------------------------------------------------
# 3. The real acceptance test: QMdmm's own GUI and Bot.
# ---------------------------------------------------------------------------
# QMdmmGui and QMdmmBot are ordinary application directories whose CMakeLists
# link the QMdmm6:: targets. Adding them here is only possible if the installed
# package exports exactly the interface they expect, which makes them a much
# harsher test than any hand-written consumer could be.
#
# Two things they take for granted are normally provided by QMdmm's own root
# CMakeLists, so they are supplied here:
#   * Qt 6 itself (with the modules the GUI needs),
#   * ${QMdmm_VERSION}, which QMdmm's project() call would have set - taken from
#     the version the package reports, so it cannot drift,
#   * GNUInstallDirs, for ${CMAKE_INSTALL_BINDIR}.
find_package(Qt6 6.5 REQUIRED COMPONENTS
    Core Gui Widgets
    Network WebSockets
    Qml Quick QuickWidgets
    LinguistTools
)
include(GNUInstallDirs)
set(QMdmm_VERSION "${QMdmm6_VERSION}")

add_subdirectory("${QMDMM_SOURCE_DIR}/QMdmmGui" qmdmm-gui)
add_subdirectory("${QMDMM_SOURCE_DIR}/QMdmmBot" qmdmm-bot)
