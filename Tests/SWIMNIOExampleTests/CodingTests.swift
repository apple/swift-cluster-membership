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
import Foundation
import NIO
import SWIM
@testable import SWIMNIOExample
import XCTest

final class CodingTests: XCTestCase {
    lazy var nioPeer: SWIM.NIOPeer = SWIM.NIOPeer(node: .init(protocol: "udp", host: "127.0.0.1", port: 1111, uid: 12121), channel: EmbeddedChannel())
    lazy var nioPeerOther: SWIM.NIOPeer = SWIM.NIOPeer(node: .init(protocol: "udp", host: "127.0.0.1", port: 2222, uid: 234_324), channel: EmbeddedChannel())

    lazy var memberOne = SWIM.Member(peer: nioPeer, status: .alive(incarnation: 1), protocolPeriod: 0)
    lazy var memberTwo = SWIM.Member(peer: nioPeer, status: .alive(incarnation: 2), protocolPeriod: 0)
    lazy var memberThree = SWIM.Member(peer: nioPeer, status: .alive(incarnation: 2), protocolPeriod: 0)

    // TODO: add some more "nasty" cases, since the node parsing code is very manual and not hardened / secure
    func test_serializationOf_node() throws {
        try self.shared_serializationRoundtrip(
            ContainsNode(node: Node(protocol: "udp", host: "127.0.0.1", port: 1111, uid: 12121))
        )
        try self.shared_serializationRoundtrip(
            ContainsNode(node: Node(protocol: "udp", host: "127.0.0.1", port: 1111, uid: nil))
        )
        try self.shared_serializationRoundtrip(
            ContainsNode(node: Node(protocol: "udp", host: "127.0.0.1", port: 1111, uid: .random(in: 0 ... UInt64.max)))
        )
        try self.shared_serializationRoundtrip(
            Node(protocol: "udp", host: "127.0.0.1", port: 1111, uid: .random(in: 0 ... UInt64.max))
        )

        // with name
        try self.shared_serializationRoundtrip(
            Node(protocol: "udp", name: "kappa", host: "127.0.0.1", port: 2222, uid: .random(in: 0 ... UInt64.max))
        )
    }

    func test_serializationOf_peer() throws {
        try self.shared_serializationRoundtrip(ContainsPeer(peer: self.nioPeer))
    }

    func test_serializationOf_member() throws {
        try self.shared_serializationRoundtrip(ContainsMember(member: self.memberOne))
    }

    func test_serializationOf_ping() throws {
        let payloadSome: SWIM.GossipPayload = .membership([
            self.memberOne,
            self.memberTwo,
            self.memberThree,
        ])
        try self.shared_serializationRoundtrip(SWIM.Message.ping(replyTo: self.nioPeer, payload: payloadSome, sequenceNumber: 1212))
    }

    func test_serializationOf_pingReq() throws {
        let payloadNone: SWIM.GossipPayload<SWIM.NIOPeer> = .none
        try self.shared_serializationRoundtrip(SWIM.Message.pingRequest(target: self.nioPeer, replyTo: self.nioPeerOther, payload: payloadNone, sequenceNumber: 111))

        let payloadSome: SWIM.GossipPayload = .membership([
            self.memberOne,
            self.memberTwo,
            self.memberThree,
        ])
        try self.shared_serializationRoundtrip(SWIM.Message.pingRequest(target: self.nioPeer, replyTo: self.nioPeerOther, payload: payloadSome, sequenceNumber: 1212))
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Utils

    func shared_serializationRoundtrip<T: Codable>(_ obj: T) throws {
        let repr = try SWIMNIODefaultEncoder().encode(obj)
        let decoder = SWIMNIODefaultDecoder()
        decoder.userInfo[.channelUserInfoKey] = EmbeddedChannel()
        let deserialized = try decoder.decode(T.self, from: repr)

        XCTAssertEqual("\(obj)", "\(deserialized)")
    }
}

// This is a workaround until Swift 5.2.5 is available with the "top level string value encoding" support.
struct ContainsPeer: Codable {
    let peer: SWIM.NIOPeer
}

// This is a workaround until Swift 5.2.5 is available with the "top level string value encoding" support.
struct ContainsMember: Codable {
    let member: SWIM.Member<SWIM.NIOPeer>
}

// This is a workaround until Swift 5.2.5 is available with the "top level string value encoding" support.
struct ContainsNode: Codable {
    let node: ClusterMembership.Node
}
