//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Cluster Membership open source project
//
// Copyright (c) 2018-2019 Apple Inc. and the Swift Cluster Membership project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Cluster Membership project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import ClusterMembership
import NIO
import SWIM
@testable import SWIMNIO
import XCTest
import Logging

final class SWIMNIOClusteredTests: RealClusteredXCTestCase {

    override var alwaysPrintCaptureLogs: Bool {
        true
    }

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: Black box tests, we let the nodes run and inspect their state via logs

    func test_real_peers_2_connect() throws {
        let (firstHandler, firstChannel) = self.makeClusterNode(name: "first")
        let firstNode = firstHandler.shell.node

        let (secondHandler, secondChannel) = self.makeClusterNode(name: "second") { settings in
            settings.initialContactPoints = [firstHandler.shell.node]
        }
        let secondNode = secondHandler.shell.node

        try self.capturedLogs(of: firstHandler.shell.node)
            .awaitLog(grep: #""swim/members/count": 2"#)
        try self.capturedLogs(of: secondNode)
            .awaitLog(grep: #""swim/members/count": 2"#)
    }

    func test_real_peers_5_connect() throws {
        let (first, _) = self.makeClusterNode(name: "first")
        let (second, _) = self.makeClusterNode(name: "second") { settings in
            settings.initialContactPoints = [first.shell.node]
        }
        let (third, _) = self.makeClusterNode(name: "third") { settings in
            settings.initialContactPoints = [second.shell.node]
        }
        let (fourth, _) = self.makeClusterNode(name: "fourth") { settings in
            settings.initialContactPoints = [third.shell.node]
        }
        let (fifth, _) = self.makeClusterNode(name: "fifth") { settings in
            settings.initialContactPoints = [fourth.shell.node]
        }

        try [first, second, third, fourth, fifth].forEach { handler in
            do {
                try self.capturedLogs(of: handler.shell.node)
                    .awaitLog(
                        grep: #""swim/members/count": 5"#,
                        within: .seconds(10)
                    )
            } catch {
                throw TestError("Failed to find expected logs on \(handler.shell.node)", error: error)
            }
        }
    }
}

fileprivate struct TestError: Error {
    let message: String
    let error: Error

    init(_ message: String, error: Error) {
        self.message = message
        self.error = error
    }
}