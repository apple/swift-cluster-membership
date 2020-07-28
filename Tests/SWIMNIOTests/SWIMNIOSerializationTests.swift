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
import SWIM
@testable import SWIMNIO
import XCTest

final class SWIMNIOSerializationTests: XCTestCase {
    lazy var nioPeer = SWIM.NIOPeer(node: .init(protocol: "udp", host: "127.0.0.1", port: 1111, uid: 12121), channel: nil)
    lazy var nioPeerOther = SWIM.NIOPeer(node: .init(protocol: "udp", host: "127.0.0.1", port: 2222, uid: 234_324), channel: nil)

    lazy var memberOne: SWIM.Member = .init(peer: nioPeer, status: .alive(incarnation: 1), protocolPeriod: 0) // FIXME: we don't ser/deser protocol period, bug or feature?
    lazy var memberTwo: SWIM.Member = .init(peer: nioPeer, status: .alive(incarnation: 2), protocolPeriod: 0) // FIXME: we don't ser/deser protocol period, bug or feature?
    lazy var memberThree: SWIM.Member = .init(peer: nioPeer, status: .alive(incarnation: 2), protocolPeriod: 0) // FIXME: we don't ser/deser protocol period, bug or feature?

    func test_serializationOf_ping() throws {
        try self.shared_serializationRoundtrip(self.nioPeer)
        try self.shared_serializationRoundtrip(self.memberOne)
    }

    func test_serializationOf_pingReq() throws {
        let payloadNone: SWIM.GossipPayload = .none
        try self.shared_serializationRoundtrip(SWIM.Message.pingReq(target: self.nioPeer, replyTo: self.nioPeerOther, payload: payloadNone, sequenceNr: 111))

        let payloadSome: SWIM.GossipPayload = .membership([
            self.memberOne,
            self.memberTwo,
            self.memberThree,
        ])
        try self.shared_serializationRoundtrip(SWIM.Message.pingReq(target: self.nioPeer, replyTo: self.nioPeerOther, payload: payloadSome, sequenceNr: 1212))
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Utils

    func shared_serializationRoundtrip<T: InternalProtobufRepresentable>(_ obj: T) throws {
        let proto = try obj.toProto()
        let deserialized = try! T.init(fromProto: proto)

        XCTAssertEqual("\(obj)", "\(deserialized)")
    }

    func shared_serializationRoundtrip<T: ProtobufRepresentable>(_ obj: T) throws {
        let proto = try obj.toProto()
        let deserialized = try! T.init(fromProto: proto)

        XCTAssertEqual("\(obj)", "\(deserialized)")
    }
}
