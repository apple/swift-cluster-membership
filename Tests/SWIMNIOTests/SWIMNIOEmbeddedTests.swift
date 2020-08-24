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

final class SWIMNIOEmbeddedTests: EmbeddedClusteredXCTestCase {
    let firstNode = Node(protocol: "test", host: "127.0.0.1", port: 7001, uid: 1111)
    let secondNode = Node(protocol: "test", host: "127.0.0.1", port: 7002, uid: 1111)

    func test_embedded_schedulingPeriodicTicksWorks() throws {
        let first = self.makeEmbeddedShell("first") { settings in
            settings.swim.initialContactPoints = [secondNode]
            settings.swim.node = firstNode
        }
        let second = self.makeEmbeddedShell("second") { settings in
            settings.swim.initialContactPoints = []
            settings.swim.node = secondNode
        }

        for _ in 0 ... 5 {
            self.loop.advanceTime(by: .seconds(1))
            self.exchangeMessages(first, second)
        }

        XCTAssertEqual(first.swim.allMemberCount, 2)
        XCTAssertEqual(second.swim.allMemberCount, 2)
    }

    func test_embedded_suspicionsBecomeDeadNodesAfterTime() throws {
        let first = self.makeEmbeddedShell("first") { settings in
            settings.swim.initialContactPoints = [secondNode]
            settings.swim.node = firstNode
        }
        let second = self.makeEmbeddedShell("second") { settings in
            settings.swim.initialContactPoints = []
            settings.swim.node = secondNode
        }

        for _ in 0 ... 5 {
            self.loop.advanceTime(by: .seconds(1))
            self.exchangeMessages(first, second)
        }

        XCTAssertEqual(first.swim.allMemberCount, 2)
        XCTAssertEqual(second.swim.allMemberCount, 2)

        // --- simulate cluster partition ---
        var foundSuspects = false
        var rounds = 1
        while !foundSuspects {
            self.loop.advanceTime(by: .seconds(1))
            self.timeoutPings(first, second)
            // the nodes can't send each other messages, and thus eventually emit dead warnings
            foundSuspects = first.swim.suspects.count == 1 && second.swim.suspects.count == 1
            rounds += 1
        }

        print("  Becoming suspicious of each other after a cluster partition took: \(rounds) rounds")
    }

    private func exchangeMessages(_ first: SWIMNIOShell, _ second: SWIMNIOShell) {
        let firstEmbeddedChannel = first.channel as! EmbeddedChannel
        let secondEmbeddedChannel = second.channel as! EmbeddedChannel

        if let writeCommand = try! firstEmbeddedChannel.readOutbound(as: WriteCommand.self) {
            second.receiveMessage(message: writeCommand.message)
        }
        if let writeCommand = try! secondEmbeddedChannel.readOutbound(as: WriteCommand.self) {
            first.receiveMessage(message: writeCommand.message)
        }
    }

    /// Timeout pings between nodes
    private func timeoutPings(_ first: SWIMNIOShell, _ second: SWIMNIOShell) {
        let firstEmbeddedChannel = first.channel as! EmbeddedChannel
        let secondEmbeddedChannel = second.channel as! EmbeddedChannel

        guard let writeCommand1 = try! firstEmbeddedChannel.readOutbound(as: WriteCommand.self) else {
            return
        }
        switch writeCommand1.message {
        case .ping(_, _, let sequenceNumber):
            first.receivePingResponse(response: .timeout(target: second.peer, pingRequestOrigin: nil, timeout: .milliseconds(1), sequenceNumber: sequenceNumber), pingRequestOriginPeer: nil)
        default:
            // deliver others as usual
            second.receiveMessage(message: writeCommand1.message)
        }

        guard let writeCommand2 = try! secondEmbeddedChannel.readOutbound(as: WriteCommand.self) else {
            return
        }
        switch writeCommand2.message {
        case .ping(_, _, let sequenceNumber):
            second.receivePingResponse(response: .timeout(target: second.peer, pingRequestOrigin: nil, timeout: .milliseconds(1), sequenceNumber: sequenceNumber), pingRequestOriginPeer: nil)
        default:
            // deliver others as usual
            first.receiveMessage(message: writeCommand2.message)
        }
    }
}
