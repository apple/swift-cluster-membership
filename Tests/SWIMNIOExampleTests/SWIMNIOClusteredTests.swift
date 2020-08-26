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
import Logging
import NIO
import SWIM
@testable import SWIMNIOExample
import XCTest

final class SWIMNIOClusteredTests: RealClusteredXCTestCase {
    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: White box tests // TODO: implement more of the tests in terms of inspecting events

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Black box tests, we let the nodes run and inspect their state via logs

    func test_real_peers_2_connect() throws {
        let (firstHandler, _) = self.makeClusterNode()

        let (secondHandler, _) = self.makeClusterNode() { settings in
            settings.swim.initialContactPoints = [firstHandler.shell.node]
        }

        try self.capturedLogs(of: firstHandler.shell.node)
            .awaitLog(grep: #""swim/members/count": 2"#)
        try self.capturedLogs(of: secondHandler.shell.node)
            .awaitLog(grep: #""swim/members/count": 2"#)
    }

    func test_real_peers_2_connect_first_terminates() throws {
        let (firstHandler, firstChannel) = self.makeClusterNode() { settings in
            settings.swim.pingTimeout = .milliseconds(100)
            settings.swim.probeInterval = .milliseconds(500)
        }

        let (secondHandler, _) = self.makeClusterNode() { settings in
            settings.swim.initialContactPoints = [firstHandler.shell.node]

            settings.swim.pingTimeout = .milliseconds(100)
            settings.swim.probeInterval = .milliseconds(500)
        }

        try self.capturedLogs(of: firstHandler.shell.node)
            .awaitLog(grep: #""swim/members/count": 2"#)

        // close first channel
        firstHandler.log.warning("Killing \(firstHandler.shell.node)...")
        secondHandler.log.warning("Killing \(firstHandler.shell.node)...")
        try firstChannel.close().wait()

        // we should get back down to a 1 node cluster
        // TODO: add same tests but embedded
        try self.capturedLogs(of: secondHandler.shell.node)
            .awaitLog(grep: #""swim/suspects/count": 1"#, within: .seconds(20))
    }

    func test_real_peers_2_connect_peerCountNeverExceeds2() throws {
        let (firstHandler, _) = self.makeClusterNode() { settings in
            settings.swim.pingTimeout = .milliseconds(100)
            settings.swim.probeInterval = .milliseconds(500)
        }

        let (secondHandler, _) = self.makeClusterNode() { settings in
            settings.swim.initialContactPoints = [firstHandler.shell.node]

            settings.swim.pingTimeout = .milliseconds(100)
            settings.swim.probeInterval = .milliseconds(500)
        }

        try self.capturedLogs(of: firstHandler.shell.node)
            .awaitLog(grep: #""swim/members/count": 2"#)

        sleep(5)

        do {
            let found = try self.capturedLogs(of: secondHandler.shell.node)
                .awaitLog(grep: #""swim/members/count": 3"#, within: .seconds(5))
            XCTFail("Found unexpected members count: 3! Log message: \(found)")
            return
        } catch {
            () // good!
        }
    }

    func test_real_peers_5_connect() throws {
        let (first, _) = self.makeClusterNode() { settings in
            settings.swim.probeInterval = .milliseconds(200)
        }
        let (second, _) = self.makeClusterNode() { settings in
            settings.swim.probeInterval = .milliseconds(200)
            settings.swim.initialContactPoints = [first.shell.node]
        }
        let (third, _) = self.makeClusterNode() { settings in
            settings.swim.probeInterval = .milliseconds(200)
            settings.swim.initialContactPoints = [second.shell.node]
        }
        let (fourth, _) = self.makeClusterNode() { settings in
            settings.swim.probeInterval = .milliseconds(200)
            settings.swim.initialContactPoints = [third.shell.node]
        }
        let (fifth, _) = self.makeClusterNode() { settings in
            settings.swim.probeInterval = .milliseconds(200)
            settings.swim.initialContactPoints = [fourth.shell.node]
        }

        try [first, second, third, fourth, fifth].forEach { handler in
            do {
                try self.capturedLogs(of: handler.shell.node)
                    .awaitLog(
                        grep: #""swim/members/count": 5"#,
                        within: .seconds(5)
                    )
            } catch {
                throw TestError("Failed to find expected logs on \(handler.shell.node)", error: error)
            }
        }
    }

    func test_real_peers_5_connect_butSlowly() throws {
        let (first, _) = self.makeClusterNode() { settings in
            settings.swim.pingTimeout = .milliseconds(100)
            settings.swim.probeInterval = .milliseconds(500)
        }
        let (second, _) = self.makeClusterNode() { settings in
            settings.swim.initialContactPoints = [first.shell.node]
            settings.swim.pingTimeout = .milliseconds(100)
            settings.swim.probeInterval = .milliseconds(500)
        }
        // we sleep in order to ensure we exhaust the "gossip at most ... times" logic
        sleep(4)
        let (third, _) = self.makeClusterNode() { settings in
            settings.swim.initialContactPoints = [second.shell.node]
            settings.swim.pingTimeout = .milliseconds(100)
            settings.swim.probeInterval = .milliseconds(500)
        }
        let (fourth, _) = self.makeClusterNode() { settings in
            settings.swim.initialContactPoints = [third.shell.node]
            settings.swim.pingTimeout = .milliseconds(100)
            settings.swim.probeInterval = .milliseconds(500)
        }
        // after joining two more, we sleep again to make sure they all exhaust their gossip message counts
        sleep(2)
        let (fifth, _) = self.makeClusterNode() { settings in
            // we connect fir the first, they should exchange all information
            settings.swim.initialContactPoints = [
                first.shell.node,
                fourth.shell.node,
            ]
        }

        try [first, second, third, fourth, fifth].forEach { handler in
            do {
                try self.capturedLogs(of: handler.shell.node)
                    .awaitLog(
                        grep: #""swim/members/count": 5"#,
                        within: .seconds(5)
                    )
            } catch {
                throw TestError("Failed to find expected logs on \(handler.shell.node)", error: error)
            }
        }
    }

    func test_real_peers_5_then1Dies_becomesSuspect() throws {
        let (first, firstChannel) = self.makeClusterNode() { settings in
            settings.swim.pingTimeout = .milliseconds(100)
            settings.swim.probeInterval = .milliseconds(500)
        }
        let (second, _) = self.makeClusterNode() { settings in
            settings.swim.initialContactPoints = [first.shell.node]
            settings.swim.pingTimeout = .milliseconds(100)
            settings.swim.probeInterval = .milliseconds(500)
        }
        let (third, _) = self.makeClusterNode() { settings in
            settings.swim.initialContactPoints = [second.shell.node]
            settings.swim.pingTimeout = .milliseconds(100)
            settings.swim.probeInterval = .milliseconds(500)
        }
        let (fourth, _) = self.makeClusterNode() { settings in
            settings.swim.initialContactPoints = [third.shell.node]
            settings.swim.pingTimeout = .milliseconds(100)
            settings.swim.probeInterval = .milliseconds(500)
        }
        let (fifth, _) = self.makeClusterNode() { settings in
            settings.swim.initialContactPoints = [fourth.shell.node]
            settings.swim.pingTimeout = .milliseconds(100)
            settings.swim.probeInterval = .milliseconds(500)
        }

        try [first, second, third, fourth, fifth].forEach { handler in
            do {
                try self.capturedLogs(of: handler.shell.node)
                    .awaitLog(
                        grep: #""swim/members/count": 5"#,
                        within: .seconds(20)
                    )
            } catch {
                throw TestError("Failed to find expected logs on \(handler.shell.node)", error: error)
            }
        }

        try firstChannel.close().wait()

        try [second, third, fourth, fifth].forEach { handler in
            do {
                try self.capturedLogs(of: handler.shell.node)
                    .awaitLog(
                        grep: #""swim/suspects/count": 1"#,
                        within: .seconds(10)
                    )
            } catch {
                throw TestError("Failed to find expected logs on \(handler.shell.node)", error: error)
            }
        }
    }

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: nack tests

    func test_real_pingRequestsGetSent_nacksArriveBack() throws {
        let (firstHandler, _) = self.makeClusterNode()
        let (secondHandler, _) = self.makeClusterNode() { settings in
            settings.swim.initialContactPoints = [firstHandler.shell.node]
        }
        let (thirdHandler, thirdChannel) = self.makeClusterNode() { settings in
            settings.swim.initialContactPoints = [firstHandler.shell.node, secondHandler.shell.node]
        }

        try self.capturedLogs(of: firstHandler.shell.node)
            .awaitLog(grep: #""swim/members/count": 3"#)
        try self.capturedLogs(of: secondHandler.shell.node)
            .awaitLog(grep: #""swim/members/count": 3"#)
        try self.capturedLogs(of: thirdHandler.shell.node)
            .awaitLog(grep: #""swim/members/count": 3"#)

        try thirdChannel.close().wait()

        try self.capturedLogs(of: firstHandler.shell.node)
            .awaitLog(grep: "Read successful: response/nack")
        try self.capturedLogs(of: secondHandler.shell.node)
            .awaitLog(grep: "Read successful: response/nack")

        try self.capturedLogs(of: firstHandler.shell.node)
            .awaitLog(grep: #""swim/suspects/count": 1"#)
        try self.capturedLogs(of: secondHandler.shell.node)
            .awaitLog(grep: #""swim/suspects/count": 1"#)
    }
}

private struct TestError: Error {
    let message: String
    let error: Error

    init(_ message: String, error: Error) {
        self.message = message
        self.error = error
    }
}
