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
@testable import SWIM
@testable import SWIMNIOExample
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

    func test_embedded_handleMissedNacks_whenTimingOut() throws {
        let thirdNode = Node(protocol: "test", host: "127.0.0.1", port: 7003, uid: 1111)
        let unreachableNode = Node(protocol: "test", host: "127.0.0.1", port: 7004, uid: 1111)

        let first = self.makeEmbeddedShell("first") { settings in
            settings.swim.node = firstNode
            settings.swim.initialContactPoints = [secondNode, thirdNode, unreachableNode]
            settings._startPeriodicPingTimer = false
            settings.swim.lifeguard.maxLocalHealthMultiplier = 8
            settings.swim.extensionUnreachability = .enabled
        }

        let second = self.makeEmbeddedShell("second") { settings in
            settings.swim.node = secondNode
            settings.swim.initialContactPoints = []
            settings._startPeriodicPingTimer = false
            settings.swim.extensionUnreachability = .enabled
        }

        let third = self.makeEmbeddedShell("third") { settings in
            settings.swim.node = thirdNode
            settings.swim.initialContactPoints = []
            settings._startPeriodicPingTimer = false
            settings.swim.extensionUnreachability = .enabled
        }

        let unreachable = self.makeEmbeddedShell("unreachable") { settings in
            settings.swim.node = unreachableNode
            settings.swim.initialContactPoints = []
            settings._startPeriodicPingTimer = false
            settings.swim.extensionUnreachability = .enabled
        }

        // Allow initial message passing to let first node recognize peers as SWIMMembers
        self.exchangeMessages(first, second)
        self.exchangeMessages(first, third)
        self.exchangeMessages(first, unreachable)

        let unreachablePeer = unreachable.peer

        XCTAssertEqual(first.swim.localHealthMultiplier, 0)
        first.sendPing(to: unreachablePeer, pingRequestOriginPeer: nil, timeout: .milliseconds(100), sequenceNumber: 4)
        self.timeoutPings(first, unreachable)
        XCTAssertEqual(first.swim.localHealthMultiplier, 1)
        self.timeoutPings(first, second)
        XCTAssertEqual(first.swim.localHealthMultiplier, 2)
        self.timeoutPings(first, third)
        XCTAssertEqual(first.swim.localHealthMultiplier, 3)
    }

    func test_embedded_handleNacks_whenPingTimeout() throws {
        let thirdNode = Node(protocol: "test", host: "127.0.0.1", port: 7003, uid: 1111)
        let unreachableNode = Node(protocol: "test", host: "127.0.0.1", port: 7004, uid: 1111)

        let first = self.makeEmbeddedShell("first") { settings in
            settings.swim.initialContactPoints = [secondNode, thirdNode, unreachableNode]
            settings._startPeriodicPingTimer = false
            settings.swim.lifeguard.maxLocalHealthMultiplier = 8
            settings.swim.node = firstNode
            settings.swim.extensionUnreachability = .enabled
        }

        let second = self.makeEmbeddedShell("second") { settings in
            settings.swim.initialContactPoints = []
            settings._startPeriodicPingTimer = false
            settings.swim.node = secondNode
        }

        let third = self.makeEmbeddedShell("third") { settings in
            settings.swim.initialContactPoints = []
            settings._startPeriodicPingTimer = false
            settings.swim.node = thirdNode
        }

        let unreachable = self.makeEmbeddedShell("unreachable") { settings in
            settings.swim.initialContactPoints = []
            settings._startPeriodicPingTimer = false
            settings.swim.node = unreachableNode
        }

        // Allow initial message passing to let first node recognize peers as SWIMMembers
        self.exchangeMessages(first, second)
        self.exchangeMessages(first, third)
        self.exchangeMessages(first, unreachable)

        let unreachablePeer = unreachable.peer

        XCTAssertEqual(first.swim.localHealthMultiplier, 0)
        first.sendPing(to: unreachablePeer, pingRequestOriginPeer: nil, timeout: .milliseconds(100), sequenceNumber: 4)
        self.timeoutPings(first, unreachable)
        XCTAssertEqual(first.swim.localHealthMultiplier, 1)
        // Sending ping requests. It's a one directional communication, the reply won't be ready until
        // we enforce communication roundtrip between indirect ping peer and ping target
        self.sendMessage(from: first, to: second)
        self.sendMessage(from: first, to: third)
        self.timeoutPings(second, unreachable, pingRequestOrigin: first.peer)
        // Sending `nack`
        self.sendMessage(from: second, to: first)
        XCTAssertEqual(first.swim.localHealthMultiplier, 1)
        self.timeoutPings(third, unreachable, pingRequestOrigin: first.peer)
        // Sending `nack`
        self.sendMessage(from: third, to: first)
        XCTAssertEqual(first.swim.localHealthMultiplier, 1)
    }

    private func exchangeMessages(_ first: SWIMNIOShell, _ second: SWIMNIOShell) {
        let firstEmbeddedChannel = first.channel as! EmbeddedChannel
        let secondEmbeddedChannel = second.channel as! EmbeddedChannel

        if let writeCommand = try! firstEmbeddedChannel.readOutbound(as: SWIMNIOWriteCommand.self) {
            second.receiveMessage(message: writeCommand.message)
        }
        if let writeCommand = try! secondEmbeddedChannel.readOutbound(as: SWIMNIOWriteCommand.self) {
            first.receiveMessage(message: writeCommand.message)
        }
    }

    private func sendMessage(from first: SWIMNIOShell, to second: SWIMNIOShell) {
        let firstEmbeddedChannel = first.channel as! EmbeddedChannel

        if let writeCommand = try! firstEmbeddedChannel.readOutbound(as: SWIMNIOWriteCommand.self) {
            second.receiveMessage(message: writeCommand.message)
        }
    }

    /// Timeout pings between nodes
    private func timeoutPings(_ first: SWIMNIOShell, _ second: SWIMNIOShell, pingRequestOrigin: SWIMPingRequestOriginPeer? = nil) {
        let firstEmbeddedChannel = first.channel as! EmbeddedChannel
        let secondEmbeddedChannel = second.channel as! EmbeddedChannel

        guard let writeCommand1 = try! firstEmbeddedChannel.readOutbound(as: SWIMNIOWriteCommand.self) else {
            return
        }
        switch writeCommand1.message {
        case .ping(_, _, let sequenceNumber), .pingRequest(_, _, _, let sequenceNumber):
            first.receivePingResponse(response: .timeout(target: second.peer, pingRequestOrigin: pingRequestOrigin, timeout: .milliseconds(1), sequenceNumber: sequenceNumber), pingRequestOriginPeer: pingRequestOrigin)
        default:
            // deliver others as usual
            second.receiveMessage(message: writeCommand1.message)
        }

        guard let writeCommand2 = try! secondEmbeddedChannel.readOutbound(as: SWIMNIOWriteCommand.self) else {
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
