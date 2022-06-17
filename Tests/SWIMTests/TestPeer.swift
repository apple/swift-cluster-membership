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
@testable import SWIM
import XCTest

final class TestPeer: Hashable, SWIMPeer, SWIMPingOriginPeer, SWIMPingRequestOriginPeer, CustomStringConvertible {
    var node: Node

    let lock = NSLock()
    var messages: [TestPeer.Message] = []

    enum Message {
        case ping(
            payload: SWIM.GossipPayload,
            origin: SWIMPingOriginPeer,
            timeout: DispatchTimeInterval,
            sequenceNumber: SWIM.SequenceNumber,
            continuation: CheckedContinuation<SWIM.PingResponse, Error>
        )
        case pingReq(
            target: SWIMAddressablePeer,
            payload: SWIM.GossipPayload,
            origin: SWIMPingRequestOriginPeer,
            timeout: DispatchTimeInterval,
            sequenceNumber: SWIM.SequenceNumber,
            continuation: CheckedContinuation<SWIM.PingResponse, Error>
        )
        case ack(
            target: SWIMPeer,
            incarnation: SWIM.Incarnation,
            payload: SWIM.GossipPayload,
            sequenceNumber: SWIM.SequenceNumber
        )
        case nack(
            target: SWIMPeer,
            sequenceNumber: SWIM.SequenceNumber
        )
    }

    init(node: Node) {
        self.node = node
    }

    func ping(
        payload: SWIM.GossipPayload,
        from pingOrigin: SWIMPingOriginPeer,
        timeout: DispatchTimeInterval,
        sequenceNumber: SWIM.SequenceNumber
    ) async throws -> SWIM.PingResponse {
        self.lock.lock()
        defer { self.lock.unlock() }

        return try await withCheckedThrowingContinuation { continuation in
            self.messages.append(.ping(payload: payload, origin: pingOrigin, timeout: timeout, sequenceNumber: sequenceNumber, continuation: continuation))
        }
    }

    func pingRequest(
        target: SWIMPeer,
        payload: SWIM.GossipPayload,
        from origin: SWIMPingRequestOriginPeer,
        timeout: DispatchTimeInterval,
        sequenceNumber: SWIM.SequenceNumber
    ) async throws -> SWIM.PingResponse {
        self.lock.lock()
        defer { self.lock.unlock() }

        return try await withCheckedThrowingContinuation { continuation in
            self.messages.append(.pingReq(target: target, payload: payload, origin: origin, timeout: timeout, sequenceNumber: sequenceNumber, continuation: continuation))
        }
    }

    func ack(
        acknowledging sequenceNumber: SWIM.SequenceNumber,
        target: SWIMPeer,
        incarnation: SWIM.Incarnation,
        payload: SWIM.GossipPayload
    ) {
        self.lock.lock()
        defer { self.lock.unlock() }

        self.messages.append(.ack(target: target, incarnation: incarnation, payload: payload, sequenceNumber: sequenceNumber))
    }

    func nack(
        acknowledging sequenceNumber: SWIM.SequenceNumber,
        target: SWIMPeer
    ) {
        self.lock.lock()
        defer { self.lock.unlock() }

        self.messages.append(.nack(target: target, sequenceNumber: sequenceNumber))
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(self.node)
    }

    static func == (lhs: TestPeer, rhs: TestPeer) -> Bool {
        if lhs === rhs {
            return true
        }
        if type(of: lhs) != type(of: rhs) {
            return false
        }
        if lhs.node != rhs.node {
            return false
        }
        return true
    }

    var description: String {
        "TestPeer(\(self.node))"
    }
}
