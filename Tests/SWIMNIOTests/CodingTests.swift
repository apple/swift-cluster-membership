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
import SWIM
@testable import SWIMNIO
import XCTest

final class CodingTests: XCTestCase {
    lazy var nioPeer = SWIM.NIOPeer(node: .init(protocol: "udp", host: "127.0.0.1", port: 1111, uid: 12121), channel: nil)
    lazy var nioPeerOther = SWIM.NIOPeer(node: .init(protocol: "udp", host: "127.0.0.1", port: 2222, uid: 234_324), channel: nil)

    lazy var memberOne = SWIM.Member(peer: nioPeer, status: .alive(incarnation: 1), protocolPeriod: 0)
    lazy var memberTwo = SWIM.Member(peer: nioPeer, status: .alive(incarnation: 2), protocolPeriod: 0)
    lazy var memberThree = SWIM.Member(peer: nioPeer, status: .alive(incarnation: 2), protocolPeriod: 0)

    // TODO: add some more "nasty" cases, since the node parsing code is very manual and not hardened / secure
    func test_serializationOf_node() throws {
        try self.shared_serializationRoundtrip(
            Node(protocol: "udp", host: "127.0.0.1", port: 1111, uid: 12121)
        )
        try self.shared_serializationRoundtrip(
            Node(protocol: "udp", host: "127.0.0.1", port: 1111, uid: nil)
        )
    }

    func test_serializationOf_ping() throws {
        try self.shared_serializationRoundtrip(self.nioPeer)
        try self.shared_serializationRoundtrip(self.memberOne)
    }

    func test_serializationOf_pingReq() throws {
        let payloadNone: SWIM.GossipPayload = .none
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
        let deserialized = try SWIMNIODefaultDecoder().decode(T.self, from: repr)

        XCTAssertEqual("\(obj)", "\(deserialized)")
    }
}
