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
import Dispatch
@testable import SWIM
import XCTest

final class TestPeer: Hashable, SWIMPeer, SWIMPingOriginPeer, SWIMPingRequestOriginPeer, CustomStringConvertible {
    var swimNode: Node

    let semaphore = DispatchSemaphore(value: 1)
    var messages: [TestPeer.Message] = []

    enum Message {
        case ping(
            payload: SWIM.GossipPayload<TestPeer>,
            origin: TestPeer,
            timeout: Duration,
            sequenceNumber: SWIM.SequenceNumber,
            continuation: CheckedContinuation<SWIM.PingResponse<TestPeer, TestPeer>, Error>
        )
        case pingReq(
            target: TestPeer,
            payload: SWIM.GossipPayload<TestPeer>,
            origin: TestPeer,
            timeout: Duration,
            sequenceNumber: SWIM.SequenceNumber,
            continuation: CheckedContinuation<SWIM.PingResponse<TestPeer, TestPeer>, Error>
        )
        case ack(
            target: TestPeer,
            incarnation: SWIM.Incarnation,
            payload: SWIM.GossipPayload<TestPeer>,
            sequenceNumber: SWIM.SequenceNumber
        )
        case nack(
            target: TestPeer,
            sequenceNumber: SWIM.SequenceNumber
        )
    }

    init(node: Node) {
        self.swimNode = node
    }

    func ping(
        payload: SWIM.GossipPayload<TestPeer>,
        from pingOrigin: TestPeer,
        timeout: Duration,
        sequenceNumber: SWIM.SequenceNumber
    ) async throws -> SWIM.PingResponse<TestPeer, TestPeer> {
        self.semaphore.wait()
        defer { self.semaphore.signal() }

        return try await withCheckedThrowingContinuation { continuation in
            self.messages.append(.ping(payload: payload, origin: pingOrigin, timeout: timeout, sequenceNumber: sequenceNumber, continuation: continuation))
        }
    }

    func pingRequest(
        target: TestPeer,
        payload: SWIM.GossipPayload<TestPeer>,
        from origin: TestPeer,
        timeout: Duration,
        sequenceNumber: SWIM.SequenceNumber
    ) async throws -> SWIM.PingResponse<TestPeer, TestPeer> {
        self.semaphore.wait()
        defer { self.semaphore.signal() }

        return try await withCheckedThrowingContinuation { continuation in
            self.messages.append(.pingReq(target: target, payload: payload, origin: origin, timeout: timeout, sequenceNumber: sequenceNumber, continuation: continuation))
        }
    }

    func ack(
        acknowledging sequenceNumber: SWIM.SequenceNumber,
        target: TestPeer,
        incarnation: SWIM.Incarnation,
        payload: SWIM.GossipPayload<TestPeer>
    ) {
        self.semaphore.wait()
        defer { self.semaphore.signal() }

        self.messages.append(.ack(target: target, incarnation: incarnation, payload: payload, sequenceNumber: sequenceNumber))
    }

    func nack(
        acknowledging sequenceNumber: SWIM.SequenceNumber,
        target: TestPeer
    ) {
        self.semaphore.wait()
        defer { self.semaphore.signal() }

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
        "TestPeer(\(self.swimNode))"
    }
}
