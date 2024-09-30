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
import Testing

actor TestPeer: @preconcurrency Codable,
                Hashable,
                SWIMPeer,
                SWIMPingOriginPeer,
                SWIMPingRequestOriginPeer,
                CustomStringConvertible {
    
    nonisolated(unsafe) var swimNode: Node
    var messages: [TestPeer.Message] = []
    
    // FIXME: .ping and .pingRequest are not used. Cover it with tests and remove this error.
    enum Error: Swift.Error {
        case notUsedAtTheMoment
    }
    
    enum Message: Codable {
        case ping(
            payload: SWIM.GossipPayload<TestPeer>?,
            origin: TestPeer,
            timeout: Duration,
            sequenceNumber: SWIM.SequenceNumber
        )
        case pingReq(
            target: TestPeer,
            payload: SWIM.GossipPayload<TestPeer>?,
            origin: TestPeer,
            timeout: Duration,
            sequenceNumber: SWIM.SequenceNumber
        )
        case ack(
            target: TestPeer,
            incarnation: SWIM.Incarnation,
            payload: SWIM.GossipPayload<TestPeer>?,
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
        payload: SWIM.GossipPayload<TestPeer>?,
        from pingOrigin: TestPeer,
        timeout: Duration,
        sequenceNumber: SWIM.SequenceNumber
    ) async throws -> SWIM.PingResponse<TestPeer, TestPeer> {
        throw Error.notUsedAtTheMoment
        // FIXME: Apparently not used, would be nice to mock and test it
        let response = Message.ping(
            payload: payload,
            origin: pingOrigin,
            timeout: timeout,
            sequenceNumber: sequenceNumber
        )
        self.messages.append(response)
    }
    
    func pingRequest(
        target: TestPeer,
        payload: SWIM.GossipPayload<TestPeer>?,
        from origin: TestPeer,
        timeout: Duration,
        sequenceNumber: SWIM.SequenceNumber
    ) async throws -> SWIM.PingResponse<TestPeer, TestPeer> {
        throw Error.notUsedAtTheMoment
        // FIXME: Apparently not used, would be nice to mock and test it
        self.messages.append(
            .pingReq(
                target: target,
                payload: payload,
                origin: origin,
                timeout: timeout,
                sequenceNumber: sequenceNumber
            )
        )
    }
    
    func ack(
        acknowledging sequenceNumber: SWIM.SequenceNumber,
        target: TestPeer,
        incarnation: SWIM.Incarnation,
        payload: SWIM.GossipPayload<TestPeer>?
    ) {
        self.messages.append(
            .ack(
                target: target,
                incarnation: incarnation,
                payload: payload,
                sequenceNumber: sequenceNumber
            )
        )
    }
    
    func nack(
        acknowledging sequenceNumber: SWIM.SequenceNumber,
        target: TestPeer
    ) {
        self.messages.append(
            .nack(
                target: target,
                sequenceNumber: sequenceNumber
            )
        )
    }
    
    nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(self.node)
    }
    
    nonisolated static func == (lhs: TestPeer, rhs: TestPeer) -> Bool {
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
    
    nonisolated var description: String {
        "TestPeer(\(self.swimNode))"
    }
}
