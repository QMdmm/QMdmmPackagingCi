# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Acceptance harness for the *installed* QMdmm dev package.
#
# Nothing in this project reaches into the QMdmm build tree for headers,
# libraries or targets. The only thing it takes from the source tree is the GUI,
# Bot and Server sources themselves, so that "the dev package can build them" is
# tested for real instead of being approximated by a toy program.
#
# Configure it with:
#
#   cmake -S consumer -B build -G Ninja \
#       -DQMDMM_SOURCE_DIR=<checkout of QMdmm/QMdmm>

cmake_minimum_required(VERSION 3.19)

project(QMdmmConsumer LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED true)

if (NOT DEFINED QMDMM_SOURCE_DIR)
    message(FATAL_ERROR "Pass -DQMDMM_SOURCE_DIR=<checkout of QMdmm/QMdmm>")
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
# 3. The real acceptance test: QMdmm's own GUI, Bot and Server.
# ---------------------------------------------------------------------------
# QMdmmGui, QMdmmBot and QMdmmServer are ordinary application directories whose
# CMakeLists link the QMdmm6:: targets. Adding them here is only possible if the
# installed package exports exactly the interface they expect, which makes them a
# much harsher test than any hand-written consumer could be.
#
# A few things they take for granted are normally provided by QMdmm's own root
# CMakeLists, so they are supplied here:
#   * Qt 6 itself (with the modules the GUI needs),
#   * ${QMdmm_VERSION}, which QMdmm's project() call would have set - taken from
#     the version the package reports, so it cannot drift,
#   * GNUInstallDirs, for ${CMAKE_INSTALL_BINDIR}.
find_package(Qt6 6.7 REQUIRED COMPONENTS
    Core Gui Widgets
    Network WebSockets
    Qml Quick QuickWidgets
    LinguistTools
)

# QMdmm's own root calls this with the same REQUIRES, and QMdmmGui cannot be
# built without it: qt6_add_qml_module() decides the resource prefix of a QML
# module from the QTP0001 policy, which qt6_standard_project_setup() sets to NEW
# for everything introduced up to 6.7. Under the policy's old default the QML
# files land at qrc:/QMdmm/Gui/qml/..., while MainWindow hardcodes
# qrc:/qt/qml/QMdmm/Gui/qml/main.qml - the GUI would link, start, and then show
# nothing at all. Mirrored here rather than worked around, because this is
# exactly what any downstream project that builds QMdmm's GUI has to do.
qt6_standard_project_setup(REQUIRES 6.7)
include(GNUInstallDirs)
set(QMdmm_VERSION "${QMdmm6_VERSION}")

# All three applications QMdmm ships, not just the GUI and the Bot: between them
# they pull in every public header and every exported target, so "the dev package
# is sufficient" is tested against the whole surface rather than a sample of it.
add_subdirectory("${QMDMM_SOURCE_DIR}/QMdmmGui" qmdmm-gui)
add_subdirectory("${QMDMM_SOURCE_DIR}/QMdmmBot" qmdmm-bot)
add_subdirectory("${QMDMM_SOURCE_DIR}/QMdmmServer" qmdmm-server)
