//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Cluster Membership open source project
//
// Copyright (c) 2018-2022 Apple Inc. and the Swift Cluster Membership project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Cluster Membership project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import ClusterMembership
import struct Dispatch.DispatchTime
import enum Dispatch.DispatchTimeInterval
import NIO
@testable import SWIM
@testable import SWIMNIOExample
import XCTest

final class SWIMNIOEmbeddedTests: EmbeddedClusteredXCTestCase {
    let firstNode = Node(protocol: "test", host: "127.0.0.1", port: 7001, uid: 1111)
    let secondNode = Node(protocol: "test", host: "127.0.0.1", port: 7002, uid: 1111)

    func test_embedded_schedulingPeriodicTicksWorks() async throws {
        let first = self.makeEmbeddedShell("first") { settings in
            settings.swim.initialContactPoints = [secondNode]
            settings.swim.node = firstNode
        }
        let second = self.makeEmbeddedShell("second") { settings in
            settings.swim.initialContactPoints = []
            settings.swim.node = secondNode
        }

        var unfulfilledCallbacks = UnfulfilledNIOPeerCallbacks()

        for _ in 0 ... 5 {
            self.loop.advanceTime(by: .seconds(1))
            await self.exchangeMessages(first, second, unfulfilledCallbacks: &unfulfilledCallbacks)
        }

        unfulfilledCallbacks.complete()

        XCTAssertEqual(first.swim.allMemberCount, 2)
        XCTAssertEqual(second.swim.allMemberCount, 2)
    }

    func test_embedded_suspicionsBecomeDeadNodesAfterTime() async throws {
        let first = self.makeEmbeddedShell("first") { settings in
            settings.swim.initialContactPoints = [secondNode]
            settings.swim.node = firstNode
        }
        let second = self.makeEmbeddedShell("second") { settings in
            settings.swim.initialContactPoints = []
            settings.swim.node = secondNode
        }

        var unfulfilledCallbacks = UnfulfilledNIOPeerCallbacks()

        for _ in 0 ... 5 {
            self.loop.advanceTime(by: .seconds(1))
            await self.exchangeMessages(first, second, unfulfilledCallbacks: &unfulfilledCallbacks)
        }

        unfulfilledCallbacks.complete()

        XCTAssertEqual(first.swim.allMemberCount, 2)
        XCTAssertEqual(second.swim.allMemberCount, 2)

        // --- simulate cluster partition ---
        var foundSuspects = false
        var rounds = 1
        while !foundSuspects {
            self.loop.advanceTime(by: .seconds(1))
            await self.timeoutPings(first, second)
            // the nodes can't send each other messages, and thus eventually emit dead warnings
            foundSuspects = first.swim.suspects.count == 1 && second.swim.suspects.count == 1
            rounds += 1
        }

        print("  Becoming suspicious of each other after a cluster partition took: \(rounds) rounds")
    }

    func test_embedded_handleMissedNacks_whenTimingOut() async throws {
        let thirdNode = Node(protocol: "test", host: "127.0.0.1", port: 7003, uid: 1111)
        let unreachableNode = Node(protocol: "test", host: "127.0.0.1", port: 7004, uid: 1111)

        let first = self.makeEmbeddedShell("first") { settings in
            settings.swim.node = firstNode
            // FIXME: EmbeddedChannel is not thread-safe
            // Don't set contact points to prevent initial pings from getting sent. We will send them ourselves below.
            settings.swim.initialContactPoints = [] // [secondNode, thirdNode, unreachableNode]
            settings._startPeriodicPingTimer = false
            settings.swim.lifeguard.maxLocalHealthMultiplier = 8
            settings.swim.unreachability = .enabled
        }

        let second = self.makeEmbeddedShell("second") { settings in
            settings.swim.node = secondNode
            settings.swim.initialContactPoints = []
            settings._startPeriodicPingTimer = false
            settings.swim.unreachability = .enabled
        }

        let third = self.makeEmbeddedShell("third") { settings in
            settings.swim.node = thirdNode
            settings.swim.initialContactPoints = []
            settings._startPeriodicPingTimer = false
            settings.swim.unreachability = .enabled
        }

        let unreachable = self.makeEmbeddedShell("unreachable") { settings in
            settings.swim.node = unreachableNode
            settings.swim.initialContactPoints = []
            settings._startPeriodicPingTimer = false
            settings.swim.unreachability = .enabled
        }

        // Allow initial message passing to let first node recognize peers as SWIMMembers
        await self.pingAndResponse(origin: first, target: second, sequenceNumber: 1)
        await self.pingAndResponse(origin: first, target: third, sequenceNumber: 2)
        await self.pingAndResponse(origin: first, target: unreachable, sequenceNumber: 3)

        try await self.assertLocalHealthMultiplier(first, expected: 0)

        // FIXME: is this test flow correct?

        self.sendPing(origin: first, target: unreachable, payload: .none, pingRequestOrigin: nil, pingRequestSequenceNumber: nil, sequenceNumber: 4)
        // push .ping; the .timeout ping response would trigger .pingRequest
        await self.timeoutPings(first, unreachable)
        try await self.assertLocalHealthMultiplier(first, expected: 1)

        self.sendPing(origin: first, target: unreachable, payload: .none, pingRequestOrigin: first.peer, pingRequestSequenceNumber: 1, sequenceNumber: 5)
        // miss a nack
        await self.timeoutPings(first, unreachable, pingRequestOrigin: first.peer, pingRequestSequenceNumber: 1)
        try await self.assertLocalHealthMultiplier(first, expected: 1)

        // .pingRequest sent to second and third (random order)
        let (_, done2) = await self.timeoutPings(first, second) // push .pingRequest through
        if (done2) {
            try await self.assertLocalHealthMultiplier(first, expected: 2)
        }

        _ = await self.timeoutPings(first, third) // push .pingRequest through
        try await self.assertLocalHealthMultiplier(first, expected: done2 ? 3 : 2)

        // We don't know in which order the .pingRequests are sent, so in case third receives before second, check second again
        if !done2 {
            _ = await self.timeoutPings(first, second) // push .pingRequest through
            try await self.assertLocalHealthMultiplier(first, expected: 3)
        }
    }

    func test_embedded_handleNacks_whenPingTimeout() async throws {
        let thirdNode = Node(protocol: "test", host: "127.0.0.1", port: 7003, uid: 1111)
        let unreachableNode = Node(protocol: "test", host: "127.0.0.1", port: 7004, uid: 1111)

        let first = self.makeEmbeddedShell("first") { settings in
            // FIXME: EmbeddedChannel is not thread-safe
            // Don't set contact points to prevent initial pings from getting sent. We will send them ourselves below.
            settings.swim.initialContactPoints = [] // [secondNode, thirdNode, unreachableNode]
            settings._startPeriodicPingTimer = false
            settings.swim.lifeguard.maxLocalHealthMultiplier = 8
            settings.swim.node = firstNode
            settings.swim.unreachability = .enabled
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
        await self.pingAndResponse(origin: first, target: second, sequenceNumber: 1)
        await self.pingAndResponse(origin: first, target: third, sequenceNumber: 2)
        await self.pingAndResponse(origin: first, target: unreachable, sequenceNumber: 3)

        try await self.assertLocalHealthMultiplier(first, expected: 0)

        // FIXME: is this test flow correct?

        self.sendPing(origin: first, target: unreachable, payload: .none, pingRequestOrigin: first.peer, pingRequestSequenceNumber: 1, sequenceNumber: 4)
        // push .ping; the .timeout ping response would trigger .pingRequest
        // Non-nil pingRequestOrigin would cause nack
        await self.timeoutPings(first, unreachable, pingRequestOrigin: first.peer, pingRequestSequenceNumber: 1)
        try await self.assertLocalHealthMultiplier(first, expected: 0)

        // .pingRequest sent to second and third (random order)
        let (_, done2) = await self.timeoutPings(first, second, pingRequestOrigin: first.peer, pingRequestSequenceNumber: 1) // push .pingRequest through
        if (done2) {
            try await self.assertLocalHealthMultiplier(first, expected: 0)
        }

        _ = await self.timeoutPings(first, third, pingRequestOrigin: first.peer, pingRequestSequenceNumber: 1) // push .pingRequest through
        try await self.assertLocalHealthMultiplier(first, expected: 0)

        // We don't know in which order the .pingRequests are sent, so in case third receives before second, check second again
        if !done2 {
            _ = await self.timeoutPings(first, second) // push .pingRequest through
            try await self.assertLocalHealthMultiplier(first, expected: 0)
        }
    }

    private func assertLocalHealthMultiplier(_ node: SWIMNIOShell, expected: Int, within: DispatchTimeInterval = .milliseconds(100), line: UInt = #line) async throws {
        let deadline = DispatchTime.now() + within

        while DispatchTime.now().uptimeNanoseconds < deadline.uptimeNanoseconds {
            if node.swim.localHealthMultiplier == expected {
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(node.swim.localHealthMultiplier, expected, line: line)
    }

    /// Returns unfulfilled callback after each round of exchange
    private func exchangeMessages(_ first: SWIMNIOShell, _ second: SWIMNIOShell, unfulfilledCallbacks: inout UnfulfilledNIOPeerCallbacks) async {
        let firstEmbeddedChannel = first.channel as! EmbeddedChannel
        let secondEmbeddedChannel = second.channel as! EmbeddedChannel

        let writeCommand1 = try! await firstEmbeddedChannel.readOutboundWriteCommand()
        if let writeCommand1 = writeCommand1 {
            if case .response = writeCommand1.message, let replyCallback2 = unfulfilledCallbacks.second.popFirst() {
                replyCallback2(.success(writeCommand1.message))
            } else {
                second.receiveMessage(message: writeCommand1.message)
            }

            if let replyCallback1 = writeCommand1.replyCallback {
                unfulfilledCallbacks.first.append(replyCallback1)
            }
        }

        let writeCommand2 = try! await secondEmbeddedChannel.readOutboundWriteCommand()
        if let writeCommand2 = writeCommand2 {
            if case .response = writeCommand2.message, let replyCallback1 = unfulfilledCallbacks.first.popFirst() {
                replyCallback1(.success(writeCommand2.message))
            } else {
                first.receiveMessage(message: writeCommand2.message)
            }

            if let replyCallback2 = writeCommand2.replyCallback {
                unfulfilledCallbacks.second.append(replyCallback2)
            }
        }
    }

    private func sendMessage(from first: SWIMNIOShell, to second: SWIMNIOShell) async {
        let firstEmbeddedChannel = first.channel as! EmbeddedChannel

        if let writeCommand = try! await firstEmbeddedChannel.readOutboundWriteCommand() {
            second.receiveMessage(message: writeCommand.message)
        }
    }

    private func sendPing(
        origin: SWIMNIOShell,
        target: SWIMNIOShell,
        payload: SWIM.GossipPayload,
        pingRequestOrigin: SWIM.NIOPeer?,
        pingRequestSequenceNumber: SWIM.SequenceNumber?,
        sequenceNumber: SWIM.SequenceNumber
    ) {
        Task {
            await origin.sendPing(
                to: target.peer,
                payload: payload,
                pingRequestOrigin: pingRequestOrigin,
                pingRequestSequenceNumber: pingRequestSequenceNumber,
                timeout: .milliseconds(100),
                sequenceNumber: sequenceNumber
            )
        }
    }

    private func pingAndResponse(origin: SWIMNIOShell, target: SWIMNIOShell, payload: SWIM.GossipPayload = .none, sequenceNumber: SWIM.SequenceNumber) async {
        self.sendPing(origin: origin, target: target, payload: .none, pingRequestOrigin: nil, pingRequestSequenceNumber: nil, sequenceNumber: sequenceNumber)

        let targetEmbeddedChannel = target.channel as! EmbeddedChannel

        // FIXME: is this correct?
        // origin invokes ping on target's channel, so it's target that writes and receives the command
        guard let pingCommand = try! await targetEmbeddedChannel.readOutboundWriteCommand() else {
            return XCTFail("Expected \(target) to receive ping from \(origin)")
        }
        target.receiveMessage(message: pingCommand.message)

        // target sends ping response to origin on its own channel
        guard let pingResponse = try! await targetEmbeddedChannel.readOutboundWriteCommand() else {
            return XCTFail("Expected \(target) to send ack to \(origin)")
        }
        guard let pingCallback = pingCommand.replyCallback else {
            return XCTFail("Expected ping to have callback")
        }
        pingCallback(.success(pingResponse.message))
    }

    /// Timeout pings between nodes
    @discardableResult
    private func timeoutPings(
        _ first: SWIMNIOShell,
        _ second: SWIMNIOShell,
        pingRequestOrigin: SWIMPingRequestOriginPeer? = nil,
        pingRequestSequenceNumber: SWIM.SequenceNumber? = nil
    ) async -> (Bool, Bool) {
        if pingRequestOrigin != nil && pingRequestSequenceNumber == nil ||
            pingRequestOrigin == nil && pingRequestSequenceNumber != nil {
            fatalError("either both or none pingRequest parameters must be set, was: \(String(reflecting: pingRequestOrigin)), \(String(reflecting: pingRequestSequenceNumber))")
        }

        let firstEmbeddedChannel = first.channel as! EmbeddedChannel
        let secondEmbeddedChannel = second.channel as! EmbeddedChannel

        var firstPingResponse = false
        var secondPingResponse = false

        if let writeCommand1 = try! await firstEmbeddedChannel.readOutboundWriteCommand() {
            switch writeCommand1.message {
            case .ping(_, _, let sequenceNumber), .pingRequest(_, _, _, let sequenceNumber):
                let response = SWIM.PingResponse.timeout(target: second.peer, pingRequestOrigin: pingRequestOrigin, timeout: .milliseconds(1), sequenceNumber: sequenceNumber)
                if let replyCallback = writeCommand1.replyCallback {
                    replyCallback(.success(.response(response)))
                } else {
                    first.receivePingResponse(
                        response: response,
                        pingRequestOriginPeer: pingRequestOrigin,
                        pingRequestSequenceNumber: pingRequestSequenceNumber
                    )
                }
                firstPingResponse = true
            default:
                // deliver others as usual
                second.receiveMessage(message: writeCommand1.message)
            }
        }

        if let writeCommand2 = try! await secondEmbeddedChannel.readOutboundWriteCommand() {
            switch writeCommand2.message {
            case .ping(_, _, let sequenceNumber), .pingRequest(_, _, _, let sequenceNumber):
                let response = SWIM.PingResponse.timeout(target: second.peer, pingRequestOrigin: pingRequestOrigin, timeout: .milliseconds(1), sequenceNumber: sequenceNumber)
                if let replyCallback = writeCommand2.replyCallback {
                    replyCallback(.success(.response(response)))
                } else {
                    second.receivePingResponse(
                        response: response,
                        pingRequestOriginPeer: pingRequestOrigin,
                        pingRequestSequenceNumber: pingRequestSequenceNumber
                    )
                }
                secondPingResponse = true
            default:
                // deliver others as usual
                first.receiveMessage(message: writeCommand2.message)
            }
        }

        return (firstPingResponse, secondPingResponse)
    }
}

private struct UnfulfilledNIOPeerCallbacks {
    typealias ReplyCallback = ((Result<SWIM.Message, Error>) -> Void)

    var first: [ReplyCallback] = []
    var second: [ReplyCallback] = []

    func complete() {
        self.first.forEach {
            $0(.failure(EmbeddedShellError.noReply))
        }
        self.second.forEach {
            $0(.failure(EmbeddedShellError.noReply))
        }
    }

    mutating func reset() {
        self.first = []
        self.second = []
    }
}

private extension Array where Element == UnfulfilledNIOPeerCallbacks.ReplyCallback {
    mutating func popFirst() -> Element? {
        guard !self.isEmpty else {
            return nil
        }
        return self.removeFirst()
    }
}

private extension EmbeddedChannel {
    func readOutboundWriteCommand(within: DispatchTimeInterval = .milliseconds(500)) async throws -> SWIMNIOWriteCommand? {
        let deadline = DispatchTime.now() + within

        while DispatchTime.now().uptimeNanoseconds < deadline.uptimeNanoseconds {
            if let writeCommand = try self.readOutbound(as: SWIMNIOWriteCommand.self) {
                return writeCommand
            }

            try await Task.sleep(nanoseconds: 10_000_000)
        }

        return nil
    }
}

private enum EmbeddedShellError: Error {
    case noReply
}
