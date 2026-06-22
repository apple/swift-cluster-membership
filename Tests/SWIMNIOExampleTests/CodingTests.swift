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
import NIO
import SWIM
import Testing

@testable import SWIMNIOExample

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

final class CodingTests {
    lazy var node = Node(protocol: "udp", host: "127.0.0.1", port: 1111, uid: 12121)
    lazy var nodeOther = Node(protocol: "udp", host: "127.0.0.1", port: 2222, uid: 234_324)

    lazy var memberOne = SWIM.Member(node: node, status: .alive(incarnation: 1), protocolPeriod: 0)
    lazy var memberTwo = SWIM.Member(node: node, status: .alive(incarnation: 2), protocolPeriod: 0)
    lazy var memberThree = SWIM.Member(node: node, status: .alive(incarnation: 2), protocolPeriod: 0)

    // TODO: add some more "nasty" cases, since the node parsing code is very manual and not hardened / secure
    @Test
    func test_serializationOf_node() throws {
        try self.shared_serializationRoundtrip(
            Node(protocol: "udp", host: "127.0.0.1", port: 1111, uid: 12121)
        )
        try self.shared_serializationRoundtrip(
            Node(protocol: "udp", host: "127.0.0.1", port: 1111, uid: nil)
        )
        try self.shared_serializationRoundtrip(
            Node(protocol: "udp", host: "127.0.0.1", port: 1111, uid: .random(in: 0...UInt64.max))
        )
        try self.shared_serializationRoundtrip(
            Node(protocol: "udp", host: "127.0.0.1", port: 1111, uid: .random(in: 0...UInt64.max))
        )

        // with name
        try self.shared_serializationRoundtrip(
            Node(protocol: "udp", name: "kappa", host: "127.0.0.1", port: 2222, uid: .random(in: 0...UInt64.max))
        )
    }

    @Test
    func test_serializationOf_member() throws {
        try self.shared_serializationRoundtrip(self.memberOne)
    }

    @Test
    func test_serializationOf_ping() throws {
        let payloadSome: SWIM.GossipPayload = .membership([
            self.memberOne,
            self.memberTwo,
            self.memberThree,
        ])
        try self.shared_serializationRoundtrip(
            SWIM.Message.ping(replyTo: self.node, payload: payloadSome, sequenceNumber: 1212)
        )
    }

    @Test
    func test_serializationOf_pingReq() throws {
        let payloadNone: SWIM.GossipPayload = .none
        try self.shared_serializationRoundtrip(
            SWIM.Message.pingRequest(
                target: self.node,
                replyTo: self.nodeOther,
                payload: payloadNone,
                sequenceNumber: 111
            )
        )

        let payloadSome: SWIM.GossipPayload = .membership([
            self.memberOne,
            self.memberTwo,
            self.memberThree,
        ])
        try self.shared_serializationRoundtrip(
            SWIM.Message.pingRequest(
                target: self.node,
                replyTo: self.nodeOther,
                payload: payloadSome,
                sequenceNumber: 1212
            )
        )
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Utils

    func shared_serializationRoundtrip<T: Codable>(_ obj: T) throws {
        let repr = try SWIMNIODefaultEncoder().encode(obj)
        let decoder = SWIMNIODefaultDecoder()
        let deserialized = try decoder.decode(T.self, from: repr)

        #expect("\(obj)" == "\(deserialized)")
    }
}
