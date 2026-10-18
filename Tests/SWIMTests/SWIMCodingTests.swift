//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Cluster Membership open source project
//
// Copyright (c) 2026 Apple Inc. and the Swift Cluster Membership project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of Swift Cluster Membership project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import ClusterMembership
import SWIM
import Testing

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

struct SWIMCodingTests {
    let node = Node(protocol: "test", name: "system", host: "127.0.0.1", port: 7337, uid: 1111)
    let otherNode = Node(protocol: "test", name: "system", host: "127.0.0.1", port: 8228, uid: 2222)

    @Test
    func test_serializationOf_ack() throws {
        let payload: SWIM.GossipPayload = .membership([
            SWIM.Member(node: self.otherNode, status: .alive(incarnation: 0), protocolPeriod: 0)
        ])
        let ack: SWIM.PingResponse = .ack(target: self.node, incarnation: 1, payload: payload, sequenceNumber: 13)

        let decoded = try self.roundTrip(ack)

        guard case .ack(let target, let incarnation, .membership(let members), let sequenceNumber) = decoded else {
            Issue.record("Expected .ack with membership payload, got \(decoded)")
            return
        }
        #expect(target == self.node)
        #expect(incarnation == 1)
        #expect(members.map(\.node) == [self.otherNode])
        #expect(sequenceNumber == 13)
    }

    @Test
    func test_serializationOf_nack() throws {
        let nack: SWIM.PingResponse = .nack(target: self.node, sequenceNumber: 13)

        let decoded = try self.roundTrip(nack)

        guard case .nack(let target, let sequenceNumber) = decoded else {
            Issue.record("Expected .nack, got \(decoded)")
            return
        }
        #expect(target == self.node)
        #expect(sequenceNumber == 13)
    }

    @Test
    func test_serializationOf_timeout_shouldThrow() {
        let timeout: SWIM.PingResponse = .timeout(target: self.node, pingRequestOrigin: nil, timeout: .seconds(1), sequenceNumber: 13)

        #expect(throws: SWIMSerializationError.self) {
            try JSONEncoder().encode(timeout)
        }
    }

    private func roundTrip(_ response: SWIM.PingResponse) throws -> SWIM.PingResponse {
        let data = try JSONEncoder().encode(response)
        return try JSONDecoder().decode(SWIM.PingResponse.self, from: data)
    }
}
