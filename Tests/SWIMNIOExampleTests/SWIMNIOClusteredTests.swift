//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Cluster Membership open source project
//
// Copyright (c) 2018-2019 Apple Inc. and the Swift Cluster Membership project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of Swift Cluster Membership project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import ClusterMembership
import Logging
import NIO
import SWIM
import SWIMTestKit
import Testing

@testable import SWIMNIOExample

@Suite(.serialized)
final class SWIMNIOClusteredTests {

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: White box tests // TODO: implement more of the tests in terms of inspecting events

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Black box tests, we let the nodes run and inspect their state via logs
    @Test
    func test_real_peers_2_connect() async throws {
        try await withRealClusteredTestScope { cluster in
            let (firstHandler, _) = await cluster.makeClusterNode()

            let (secondHandler, _) = await cluster.makeClusterNode { settings in
                settings.swim.initialContactPoints = [firstHandler.shell.node]
            }

            try await cluster.capturedLogs(of: firstHandler.shell.node)
                .log(grep: #""swim/members/count": 2"#)
            try await cluster.capturedLogs(of: secondHandler.shell.node)
                .log(grep: #""swim/members/count": 2"#)
        }
    }

    @Test
    func test_real_peers_2_connect_first_terminates() async throws {
        try await withRealClusteredTestScope { cluster in
            let (firstHandler, firstChannel) = await cluster.makeClusterNode { settings in
                settings.swim.pingTimeout = .milliseconds(100)
                settings.swim.probeInterval = .milliseconds(500)
            }

            let (secondHandler, _) = await cluster.makeClusterNode { settings in
                settings.swim.initialContactPoints = [firstHandler.shell.node]

                settings.swim.pingTimeout = .milliseconds(100)
                settings.swim.probeInterval = .milliseconds(500)
            }

            try await cluster.capturedLogs(of: firstHandler.shell.node)
                .log(grep: #""swim/members/count": 2"#)

            // close first channel
            firstHandler.log.warning("Stopping \(firstHandler.shell.node)...")
            secondHandler.log.warning("Stopping \(firstHandler.shell.node)...")
            try await firstChannel.close().get()

            // we should get back down to a 1 node cluster
            // TODO: add same tests but embedded
            try await cluster.capturedLogs(of: secondHandler.shell.node)
                .log(grep: #""swim/suspects/count": 1"#, within: .seconds(20))
        }
    }

    @Test
    func test_real_peers_2_connect_peerCountNeverExceeds2() async throws {
        try await withRealClusteredTestScope { cluster in
            let (firstHandler, _) = await cluster.makeClusterNode { settings in
                settings.swim.pingTimeout = .milliseconds(100)
                settings.swim.probeInterval = .milliseconds(500)
            }

            let (secondHandler, _) = await cluster.makeClusterNode { settings in
                settings.swim.initialContactPoints = [firstHandler.shell.node]

                settings.swim.pingTimeout = .milliseconds(100)
                settings.swim.probeInterval = .milliseconds(500)
            }

            try await cluster.capturedLogs(of: firstHandler.shell.node)
                .log(grep: #""swim/members/count": 2"#)

            try await Task.sleep(for: .seconds(5))

            do {
                let found = try await cluster.capturedLogs(of: secondHandler.shell.node)
                    .log(grep: #""swim/members/count": 3"#, within: .seconds(5))
                Issue.record("Found unexpected members count: 3! Log message: \(found)")
                return
            } catch {
                ()  // good!
            }
        }
    }

    @Test
    func test_real_peers_5_connect() async throws {
        try await withRealClusteredTestScope { cluster in
            let (first, _) = await cluster.makeClusterNode { settings in
                settings.swim.probeInterval = .milliseconds(200)
            }
            let (second, _) = await cluster.makeClusterNode { settings in
                settings.swim.probeInterval = .milliseconds(200)
                settings.swim.initialContactPoints = [first.shell.node]
            }
            let (third, _) = await cluster.makeClusterNode { settings in
                settings.swim.probeInterval = .milliseconds(200)
                settings.swim.initialContactPoints = [second.shell.node]
            }
            let (fourth, _) = await cluster.makeClusterNode { settings in
                settings.swim.probeInterval = .milliseconds(200)
                settings.swim.initialContactPoints = [third.shell.node]
            }
            let (fifth, _) = await cluster.makeClusterNode { settings in
                settings.swim.probeInterval = .milliseconds(200)
                settings.swim.initialContactPoints = [fourth.shell.node]
            }

            for handler in [first, second, third, fourth, fifth] {
                do {
                    try await cluster.capturedLogs(of: handler.shell.node)
                        .log(
                            grep: #""swim/members/count": 5"#,
                            within: .seconds(5)
                        )
                } catch {
                    throw TestError("Failed to find expected logs on \(handler.shell.node)", error: error)
                }
            }
        }
    }

    @Test
    func test_real_peers_5_connect_butSlowly() async throws {
        try await withRealClusteredTestScope { cluster in
            let (first, _) = await cluster.makeClusterNode { settings in
                settings.swim.pingTimeout = .milliseconds(100)
                settings.swim.probeInterval = .milliseconds(500)
            }
            let (second, _) = await cluster.makeClusterNode { settings in
                settings.swim.initialContactPoints = [first.shell.node]
                settings.swim.pingTimeout = .milliseconds(100)
                settings.swim.probeInterval = .milliseconds(500)
            }
            // we sleep in order to ensure we exhaust the "gossip at most ... times" logic
            try await Task.sleep(for: .seconds(4))
            let (third, _) = await cluster.makeClusterNode { settings in
                settings.swim.initialContactPoints = [second.shell.node]
                settings.swim.pingTimeout = .milliseconds(100)
                settings.swim.probeInterval = .milliseconds(500)
            }
            let (fourth, _) = await cluster.makeClusterNode { settings in
                settings.swim.initialContactPoints = [third.shell.node]
                settings.swim.pingTimeout = .milliseconds(100)
                settings.swim.probeInterval = .milliseconds(500)
            }
            // after joining two more, we sleep again to make sure they all exhaust their gossip message counts
            try await Task.sleep(for: .seconds(2))
            let (fifth, _) = await cluster.makeClusterNode { settings in
                // we connect fir the first, they should exchange all information
                settings.swim.initialContactPoints = [
                    first.shell.node,
                    fourth.shell.node,
                ]
            }

            for handler in [first, second, third, fourth, fifth] {
                do {
                    try await cluster.capturedLogs(of: handler.shell.node)
                        .log(
                            grep: #""swim/members/count": 5"#,
                            within: .seconds(5)
                        )
                } catch {
                    throw TestError("Failed to find expected logs on \(handler.shell.node)", error: error)
                }
            }
        }
    }

    @Test
    func test_real_peers_5_then1Dies_becomesSuspect() async throws {
        try await withRealClusteredTestScope { cluster in
            let (first, firstChannel) = await cluster.makeClusterNode { settings in
                settings.swim.pingTimeout = .milliseconds(100)
                settings.swim.probeInterval = .milliseconds(500)
            }
            let (second, _) = await cluster.makeClusterNode { settings in
                settings.swim.initialContactPoints = [first.shell.node]
                settings.swim.pingTimeout = .milliseconds(100)
                settings.swim.probeInterval = .milliseconds(500)
            }
            let (third, _) = await cluster.makeClusterNode { settings in
                settings.swim.initialContactPoints = [second.shell.node]
                settings.swim.pingTimeout = .milliseconds(100)
                settings.swim.probeInterval = .milliseconds(500)
            }
            let (fourth, _) = await cluster.makeClusterNode { settings in
                settings.swim.initialContactPoints = [third.shell.node]
                settings.swim.pingTimeout = .milliseconds(100)
                settings.swim.probeInterval = .milliseconds(500)
            }
            let (fifth, _) = await cluster.makeClusterNode { settings in
                settings.swim.initialContactPoints = [fourth.shell.node]
                settings.swim.pingTimeout = .milliseconds(100)
                settings.swim.probeInterval = .milliseconds(500)
            }

            for handler in [first, second, third, fourth, fifth] {
                do {
                    try await cluster.capturedLogs(of: handler.shell.node)
                        .log(
                            grep: #""swim/members/count": 5"#,
                            within: .seconds(20)
                        )
                } catch {
                    throw TestError("Failed to find expected logs on \(handler.shell.node)", error: error)
                }
            }

            try await firstChannel.close().get()

            // The first node is shut down; it won't emit further logs.
            for handler in [second, third, fourth, fifth] {
                do {
                    try await cluster.capturedLogs(of: handler.shell.node)
                        .log(
                            grep: #""swim/suspects/count": 1"#,
                            within: .seconds(10)
                        )
                } catch {
                    throw TestError("Failed to find expected logs on \(handler.shell.node)", error: error)
                }
            }
        }
    }

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: nack tests
    @Test
    func test_real_pingRequestsGetSent_nacksArriveBack() async throws {
        try await withRealClusteredTestScope { cluster in
            let (firstHandler, _) = await cluster.makeClusterNode()
            let (secondHandler, _) = await cluster.makeClusterNode { settings in
                settings.swim.initialContactPoints = [firstHandler.shell.node]
            }
            let (thirdHandler, thirdChannel) = await cluster.makeClusterNode { settings in
                settings.swim.initialContactPoints = [firstHandler.shell.node, secondHandler.shell.node]
            }

            try await cluster.capturedLogs(of: firstHandler.shell.node)
                .log(grep: #""swim/members/count": 3"#)
            try await cluster.capturedLogs(of: secondHandler.shell.node)
                .log(grep: #""swim/members/count": 3"#)
            try await cluster.capturedLogs(of: thirdHandler.shell.node)
                .log(grep: #""swim/members/count": 3"#)

            try await thirdChannel.close().get()

            try await cluster.capturedLogs(of: firstHandler.shell.node)
                .log(grep: "Read successful: response/nack")
            try await cluster.capturedLogs(of: secondHandler.shell.node)
                .log(grep: "Read successful: response/nack")

            try await cluster.capturedLogs(of: firstHandler.shell.node)
                .log(grep: #""swim/suspects/count": 1"#)
            try await cluster.capturedLogs(of: secondHandler.shell.node)
                .log(grep: #""swim/suspects/count": 1"#)
        }
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
