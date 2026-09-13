// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Smallest program that still proves the installed dev package is usable:
// it includes QMdmm public headers through both documented spellings and reports
// the compile definitions the package promises to propagate.

#include <QMdmmPlayer>
#include <QMdmmRoom>
#include <QMdmmCore/QMdmmProtocol>
#include <QMdmmNetworking/QMdmmAgent>

#include <QCoreApplication>
#include <QDebug>

using namespace QMdmmCore;
using namespace QMdmmNetworking;

int main(int argc, char **argv)
{
    const QCoreApplication app(argc, argv);

    qInfo() << "api-smoke: QMDMM_VERSION" << QMDMM_VERSION
            << "QT_VERSION_MAJOR" << QT_VERSION_MAJOR
            << "configuration prefix" << QMDMM_CONFIGURATION_PREFIX
            << "runtime data prefix" << QMDMM_RUNTIME_DATA_PREFIX;

    return 0;
}
