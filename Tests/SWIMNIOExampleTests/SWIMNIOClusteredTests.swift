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
import Testing

@Suite(.serialized)
class SWIMNIOClusteredTests {
    
    let suite: RealClustered = .init(startingPort: 9001)
    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: White box tests // TODO: implement more of the tests in terms of inspecting events

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Black box tests, we let the nodes run and inspect their state via logs
    @Test
    func test_real_peers_2_connect() async throws {
        let (firstHandler, _) = try await self.suite.makeClusterNode()

        let (secondHandler, _) = try await self.suite.makeClusterNode() { settings in
            settings.swim.initialContactPoints = [firstHandler.shell.node]
        }

        try await self.suite.clustered.capturedLogs(of: firstHandler.shell.node)
            .log(grep: #""swim/members/count": 2"#)
        try await self.suite.clustered.capturedLogs(of: secondHandler.shell.node)
            .log(grep: #""swim/members/count": 2"#)
    }

    @Test
    func test_real_peers_2_connect_first_terminates() async throws {
        let (firstHandler, firstChannel) = try await self.suite.makeClusterNode() { settings in
            settings.swim.pingTimeout = .milliseconds(100)
            settings.swim.probeInterval = .milliseconds(500)
        }

        let (secondHandler, _) = try await self.suite.makeClusterNode() { settings in
            settings.swim.initialContactPoints = [firstHandler.shell.node]

            settings.swim.pingTimeout = .milliseconds(100)
            settings.swim.probeInterval = .milliseconds(500)
        }

        try await self.suite.clustered.capturedLogs(of: firstHandler.shell.node)
            .log(grep: #""swim/members/count": 2"#)

        // close first channel
        firstHandler.log.warning("Killing \(firstHandler.shell.node)...")
        secondHandler.log.warning("Killing \(firstHandler.shell.node)...")
        try await firstChannel.close().get()

        // we should get back down to a 1 node cluster
        // TODO: add same tests but embedded
        try await self.suite.clustered.capturedLogs(of: secondHandler.shell.node)
            .log(grep: #""swim/suspects/count": 1"#, within: .seconds(20))
    }

    @Test
    func test_real_peers_2_connect_peerCountNeverExceeds2() async throws {
        let (firstHandler, _) = try await self.suite.makeClusterNode() { settings in
            settings.swim.pingTimeout = .milliseconds(100)
            settings.swim.probeInterval = .milliseconds(500)
        }

        let (secondHandler, _) = try await self.suite.makeClusterNode() { settings in
            settings.swim.initialContactPoints = [firstHandler.shell.node]

            settings.swim.pingTimeout = .milliseconds(100)
            settings.swim.probeInterval = .milliseconds(500)
        }

        try await self.suite.clustered.capturedLogs(of: firstHandler.shell.node)
            .log(grep: #""swim/members/count": 2"#)

        try await Task.sleep(for: .seconds(5))

        do {
            let found = try await self.suite.clustered.capturedLogs(of: secondHandler.shell.node)
                .log(grep: #""swim/members/count": 3"#, within: .seconds(5))
            Issue.record("Found unexpected members count: 3! Log message: \(found)")
            return
        } catch {
            () // good!
        }
    }

    @Test
    func test_real_peers_5_connect() async throws {
        let (first, _) = try await self.suite.makeClusterNode() { settings in
            settings.swim.probeInterval = .milliseconds(200)
        }
        let (second, _) = try await self.suite.makeClusterNode() { settings in
            settings.swim.probeInterval = .milliseconds(200)
            settings.swim.initialContactPoints = [first.shell.node]
        }
        let (third, _) = try await self.suite.makeClusterNode() { settings in
            settings.swim.probeInterval = .milliseconds(200)
            settings.swim.initialContactPoints = [second.shell.node]
        }
        let (fourth, _) = try await self.suite.makeClusterNode() { settings in
            settings.swim.probeInterval = .milliseconds(200)
            settings.swim.initialContactPoints = [third.shell.node]
        }
        let (fifth, _) = try await self.suite.makeClusterNode() { settings in
            settings.swim.probeInterval = .milliseconds(200)
            settings.swim.initialContactPoints = [fourth.shell.node]
        }

        for handler in [first, second, third, fourth, fifth] {
            do {
                try await self.suite.clustered.capturedLogs(of: handler.shell.node)
                    .log(
                        grep: #""swim/members/count": 5"#,
                        within: .seconds(5)
                    )
                
            } catch {
                throw TestError("Failed to find expected logs on \(handler.shell.node)", error: error)
            }
        }
    }

    @Test
    func test_real_peers_5_connect_butSlowly() async throws {
        let (first, _) = try await self.suite.makeClusterNode() { settings in
            settings.swim.pingTimeout = .milliseconds(100)
            settings.swim.probeInterval = .milliseconds(500)
        }
        let (second, _) = try await self.suite.makeClusterNode() { settings in
            settings.swim.initialContactPoints = [first.shell.node]
            settings.swim.pingTimeout = .milliseconds(100)
            settings.swim.probeInterval = .milliseconds(500)
        }
        // we sleep in order to ensure we exhaust the "gossip at most ... times" logic
        try await Task.sleep(for: .seconds(4))
        
        let (third, _) = try await self.suite.makeClusterNode() { settings in
            settings.swim.initialContactPoints = [second.shell.node]
            settings.swim.pingTimeout = .milliseconds(100)
            settings.swim.probeInterval = .milliseconds(500)
        }
        let (fourth, _) = try await self.suite.makeClusterNode() { settings in
            settings.swim.initialContactPoints = [third.shell.node]
            settings.swim.pingTimeout = .milliseconds(100)
            settings.swim.probeInterval = .milliseconds(500)
        }
        // after joining two more, we sleep again to make sure they all exhaust their gossip message counts
        try await Task.sleep(for: .seconds(2))
        let (fifth, _) = try await self.suite.makeClusterNode() { settings in
            // we connect fir the first, they should exchange all information
            settings.swim.initialContactPoints = [
                first.shell.node,
                fourth.shell.node,
            ]
        }

        for handler in [first, second, third, fourth, fifth] {
            do {
                try await self.suite.clustered.capturedLogs(of: handler.shell.node)
                    .log(
                        grep: #""swim/members/count": 5"#,
                        within: .seconds(5)
                    )
            } catch {
                throw TestError("Failed to find expected logs on \(handler.shell.node)", error: error)
            }
        }
    }

    @Test
    func test_real_peers_5_then1Dies_becomesSuspect() async throws {
        let (first, firstChannel) = try await self.suite.makeClusterNode() { settings in
            settings.swim.pingTimeout = .milliseconds(100)
            settings.swim.probeInterval = .milliseconds(500)
        }
        let (second, _) = try await self.suite.makeClusterNode() { settings in
            settings.swim.initialContactPoints = [first.shell.node]
            settings.swim.pingTimeout = .milliseconds(100)
            settings.swim.probeInterval = .milliseconds(500)
        }
        let (third, _) = try await self.suite.makeClusterNode() { settings in
            settings.swim.initialContactPoints = [second.shell.node]
            settings.swim.pingTimeout = .milliseconds(100)
            settings.swim.probeInterval = .milliseconds(500)
        }
        let (fourth, _) = try await self.suite.makeClusterNode() { settings in
            settings.swim.initialContactPoints = [third.shell.node]
            settings.swim.pingTimeout = .milliseconds(100)
            settings.swim.probeInterval = .milliseconds(500)
        }
        let (fifth, _) = try await self.suite.makeClusterNode() { settings in
            settings.swim.initialContactPoints = [fourth.shell.node]
            settings.swim.pingTimeout = .milliseconds(100)
            settings.swim.probeInterval = .milliseconds(500)
        }

        for handler in [first, second, third, fourth, fifth] {
            do {
                try await self.suite.clustered.capturedLogs(of: handler.shell.node)
                    .log(
                        grep: #""swim/members/count": 5"#,
                        within: .seconds(20)
                    )
            } catch {
                throw TestError("Failed to find expected logs on \(handler.shell.node)", error: error)
            }
        }

        try await firstChannel.close().get()

        for handler in  [second, third, fourth, fifth] {
            do {
                try await self.suite.clustered.capturedLogs(of: handler.shell.node)
                    .log(
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
    @Test
    func test_real_pingRequestsGetSent_nacksArriveBack() async throws {
        let (firstHandler, _) = try await self.suite.makeClusterNode()
        let (secondHandler, _) = try await self.suite.makeClusterNode() { settings in
            settings.swim.initialContactPoints = [firstHandler.shell.node]
        }
        let (thirdHandler, thirdChannel) = try await self.suite.makeClusterNode() { settings in
            settings.swim.initialContactPoints = [firstHandler.shell.node, secondHandler.shell.node]
        }

        try await self.suite.clustered.capturedLogs(of: firstHandler.shell.node)
            .log(grep: #""swim/members/count": 3"#)
        try await self.suite.clustered.capturedLogs(of: secondHandler.shell.node)
            .log(grep: #""swim/members/count": 3"#)
        try await self.suite.clustered.capturedLogs(of: thirdHandler.shell.node)
            .log(grep: #""swim/members/count": 3"#)

        try await thirdChannel.close().get()

        try await self.suite.clustered.capturedLogs(of: firstHandler.shell.node)
            .log(grep: "Read successful: response/nack")
        try await self.suite.clustered.capturedLogs(of: secondHandler.shell.node)
            .log(grep: "Read successful: response/nack")

        try await self.suite.clustered.capturedLogs(of: firstHandler.shell.node)
            .log(grep: #""swim/suspects/count": 1"#)
        try await self.suite.clustered.capturedLogs(of: secondHandler.shell.node)
            .log(grep: #""swim/suspects/count": 1"#)
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
