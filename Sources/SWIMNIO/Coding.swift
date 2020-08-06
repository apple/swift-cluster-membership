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
import SWIM

import class Foundation.JSONDecoder
import class Foundation.JSONEncoder

typealias SWIMNIODefaultEncoder = JSONEncoder
typealias SWIMNIODefaultDecoder = JSONDecoder

extension SWIM.Message: Codable {
    public enum DiscriminatorKeys: UInt8, Codable {
        case ping = 0
        case pingRequest = 1
        case response_ack = 2
        case response_nack = 3
    }

    public enum CodingKeys: CodingKey {
        case _case
        case replyTo
        case payload
        case sequenceNumber
        case incarnation
        case target
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        switch try container.decode(DiscriminatorKeys.self, forKey: ._case) {
        case .ping:
            let replyTo = try container.decode(SWIM.NIOPeer.self, forKey: .replyTo)
            let payload = try container.decode(SWIM.GossipPayload.self, forKey: .payload)
            let sequenceNumber = try container.decode(SWIM.SequenceNumber.self, forKey: .sequenceNumber)
            self = .ping(replyTo: replyTo, payload: payload, sequenceNumber: sequenceNumber)

        case .pingRequest:
            let target = try container.decode(SWIM.NIOPeer.self, forKey: .target)
            let replyTo = try container.decode(SWIM.NIOPeer.self, forKey: .replyTo)
            let payload = try container.decode(SWIM.GossipPayload.self, forKey: .payload)
            let sequenceNumber = try container.decode(SWIM.SequenceNumber.self, forKey: .sequenceNumber)
            self = .pingRequest(target: target, replyTo: replyTo, payload: payload, sequenceNumber: sequenceNumber)

        case .response_ack:
            let target = try container.decode(Node.self, forKey: .target)
            let incarnation = try container.decode(SWIM.Incarnation.self, forKey: .incarnation)
            let payload = try container.decode(SWIM.GossipPayload.self, forKey: .payload)
            let sequenceNumber = try container.decode(SWIM.SequenceNumber.self, forKey: .sequenceNumber)
            self = .response(.ack(target: target, incarnation: incarnation, payload: payload, sequenceNumber: sequenceNumber))

        case .response_nack:
            let target = try container.decode(Node.self, forKey: .target)
            let sequenceNumber = try container.decode(SWIM.SequenceNumber.self, forKey: .sequenceNumber)
            self = .response(.nack(target: target, sequenceNumber: sequenceNumber))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .ping(let replyTo, let payload, let sequenceNumber):
            try container.encode(DiscriminatorKeys.ping, forKey: ._case)
            try container.encode(replyTo, forKey: .replyTo)
            try container.encode(payload, forKey: .payload)
            try container.encode(sequenceNumber, forKey: .sequenceNumber)

        case .pingRequest(let target, let replyTo, let payload, let sequenceNumber):
            try container.encode(DiscriminatorKeys.pingRequest, forKey: ._case)
            try container.encode(target, forKey: .target)
            try container.encode(replyTo, forKey: .replyTo)
            try container.encode(payload, forKey: .payload)
            try container.encode(sequenceNumber, forKey: .sequenceNumber)

        case .response(.ack(let target, let incarnation, let payload, let sequenceNumber)):
            try container.encode(DiscriminatorKeys.response_ack, forKey: ._case)
            try container.encode(target, forKey: .target)
            try container.encode(incarnation, forKey: .incarnation)
            try container.encode(payload, forKey: .payload)
            try container.encode(sequenceNumber, forKey: .sequenceNumber)

        case .response(.nack(let target, let sequenceNumber)):
            try container.encode(DiscriminatorKeys.response_nack, forKey: ._case)
            try container.encode(target, forKey: .target)
            try container.encode(sequenceNumber, forKey: .sequenceNumber)

        case .response(let other):
            fatalError("SWIM.Message.response(\(other)) MUST NOT be serialized, this is a bug, please report an issue.")
        }
    }
}

extension SWIM.NIOPeer: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.node = try container.decode(Node.self)
        self.channel = nil
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(self.node)
    }
}

extension SWIM.Member: Codable {
    public enum CodingKeys: CodingKey {
        case node
        case status
        case protocolPeriod
        case suspicionStartedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // FIXME: use to get the channel decoder.userInfo[]
        let peer = SWIM.NIOPeer(node: try container.decode(Node.self, forKey: .node), channel: nil)
        let status = try container.decode(SWIM.Status.self, forKey: .status)
        let protocolPeriod = try container.decode(Int.self, forKey: .protocolPeriod)
        let suspicionStartedAt = try container.decodeIfPresent(Int64.self, forKey: .suspicionStartedAt)
        self.init(peer: peer, status: status, protocolPeriod: protocolPeriod, suspicionStartedAt: suspicionStartedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.node, forKey: .node)
        try container.encode(self.protocolPeriod, forKey: .protocolPeriod)
        try container.encode(self.status, forKey: .status)
        try container.encodeIfPresent(self.suspicionStartedAt, forKey: .suspicionStartedAt)
    }
}

extension ClusterMembership.Node: Codable {
    // TODO: This implementation has to parse a simplified URI-like representation of a node; need to harden the impl some more
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        // Repr is expected in format: `protocol://host:port#uid`
        let repr = try container.decode(String.self)[...]
        var atIndex = repr.startIndex

        // protocol
        guard let protocolEndIndex = repr.firstIndex(of: ":") else {
            throw SWIMSerializationError.missingField("`protocol`, in \(repr)", type: "String")
        }
        atIndex = protocolEndIndex
        let proto = String(repr[..<atIndex])

        // ://
        atIndex = repr.index(after: atIndex)
        guard repr[repr.index(after: atIndex)] == "/" else {
            throw SWIMSerializationError.missingData("Node format illegal, was: \(repr)")
        }
        atIndex = repr.index(after: atIndex)
        guard repr[repr.index(after: protocolEndIndex)] == "/" else {
            throw SWIMSerializationError.missingData("Node format illegal, was: \(repr)")
        }

        // host
        let hostStartIndex = repr.index(after: atIndex)
        guard let hostEndIndex = repr[hostStartIndex...].firstIndex(of: ":") else {
            throw SWIMSerializationError.missingData("Node format illegal, was: \(repr)")
        }
        atIndex = hostEndIndex
        // TODO: probably missing a guard if there was no : here
        let host = String(repr[hostStartIndex ..< hostEndIndex])

        // :
        atIndex = repr.index(after: atIndex)
        // port
        let portEndIndex = repr[atIndex...].firstIndex(of: "#") ?? repr.endIndex
        guard let port = Int(String(repr[atIndex ..< (portEndIndex)])) else {
            throw SWIMSerializationError.missingData("Node format illegal, missing port, was: \(repr)")
        }

        let uid: UInt64?
        if portEndIndex < repr.endIndex, repr[portEndIndex] == "#" {
            atIndex = repr.index(after: portEndIndex)
            let uidSubString = repr[atIndex ..< repr.endIndex]
            if uidSubString.isEmpty {
                uid = nil
            } else {
                uid = UInt64(uidSubString)
            }
        } else {
            uid = nil
        }

        self.init(protocol: proto, host: host, port: port, uid: uid)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        var repr = "\(self.protocol)://\(self.host):\(self.port)"
        if let uid = self.uid {
            repr.append("#\(uid)")
        }
        try container.encode(repr)
    }
}

extension SWIM.GossipPayload: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let members = try container.decode(SWIM.Members.self)
        if members.isEmpty {
            self = .none
        } else {
            self = .membership(members)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch self {
        case .none:
            let empty: SWIM.Members = []
            try container.encode(empty)

        case .membership(let members):
            try container.encode(members)
        }
    }
}

extension SWIM.Status: Codable {
    public enum DiscriminatorKeys: Int, Codable {
        case alive
        case suspect
        case unreachable
        case dead
    }

    public enum CodingKeys: CodingKey {
        case _status
        case incarnation
        case suspectedBy
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(DiscriminatorKeys.self, forKey: ._status) {
        case .alive:
            let incarnation = try container.decode(SWIM.Incarnation.self, forKey: .incarnation)
            self = .alive(incarnation: incarnation)

        case .suspect:
            let incarnation = try container.decode(SWIM.Incarnation.self, forKey: .incarnation)
            let suspectedBy = try container.decode(Set<Node>.self, forKey: .suspectedBy)
            self = .suspect(incarnation: incarnation, suspectedBy: suspectedBy)

        case .unreachable:
            let incarnation = try container.decode(SWIM.Incarnation.self, forKey: .incarnation)
            self = .unreachable(incarnation: incarnation)

        case .dead:
            self = .dead
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .alive(let incarnation):
            try container.encode(DiscriminatorKeys.alive, forKey: ._status)
            try container.encode(incarnation, forKey: .incarnation)

        case .suspect(let incarnation, let suspectedBy):
            try container.encode(DiscriminatorKeys.suspect, forKey: ._status)
            try container.encode(incarnation, forKey: .incarnation)
            try container.encode(suspectedBy, forKey: .suspectedBy)

        case .unreachable(let incarnation):
            try container.encode(DiscriminatorKeys.unreachable, forKey: ._status)
            try container.encode(incarnation, forKey: .incarnation)

        case .dead:
            try container.encode(DiscriminatorKeys.dead, forKey: ._status)
        }
    }
}

//
//    public init(fromProto proto: ProtoSWIMStatus) throws {
//        switch proto.type {
//        case .alive:
//            self = .alive(incarnation: proto.incarnation)
//        case .suspect:
//            let suspectedBy = try Set(proto.suspectedBy.map {
//                try Node(fromProto: $0)
//            })
//            self = .suspect(incarnation: proto.incarnation, suspectedBy: suspectedBy)
//        case .unreachable:
//            self = .unreachable(incarnation: proto.incarnation)
//        case .dead:
//            self = .dead
//        case .unspecified:
//            throw SWIMSerializationError.missingField("type", type: String(describing: SWIM.Status.self))
//        case .UNRECOGNIZED(let num):
//            throw SWIMSerializationError.unknownEnumValue(num)
//        }
//    }
// }
//
// extension SWIM.GossipPayload: ProtobufRepresentable {
//    public typealias ProtobufRepresentation = ProtoSWIMPayload
//
//    public func toProto() throws -> ProtoSWIMPayload {
//        var payload = ProtoSWIMPayload()
//        if case .membership(let members) = self {
//            payload.members = try members.map {
//                try $0.toProto()
//            }
//        }
//
//        return payload
//    }
//
//    public init(fromProto proto: ProtoSWIMPayload) throws {
//        if proto.members.isEmpty {
//            self = .none
//        } else {
//            let members = try proto.members.map { proto in
//                try SWIM.Member(fromProto: proto)
//            }
//            self = .membership(members)
//        }
//    }
// }
//
// extension SWIM.Member: ProtobufRepresentable {
//    public typealias ProtobufRepresentation = ProtoSWIMMember
//
//    public func toProto() throws -> ProtoSWIMMember {
//        var proto = ProtoSWIMMember()
//        let node: ClusterMembership.Node
//
//        if let nioPeer = self.peer as? SWIM.NIOPeer {
//            node = nioPeer.node
//        } else if let _node = self.peer as? ClusterMembership.Node {
//            node = _node
//        } else {
//            fatalError("Unexpected peer type: [\(self.peer)]:\(String(reflecting: type(of: self.peer))), member: \(self)")
//        }
//
//        var peer = ProtoPeer()
//        peer.node = try node.toProto()
//        proto.peer = peer
//        // proto.peer = try nioPeer.toProto()
//
//        proto.status = try self.status.toProto()
//        return proto
//    }
//
//    public init(fromProto proto: ProtoSWIMMember) throws {
//        let peer = try SWIM.NIOPeer(fromProto: proto.peer)
//        let status = try SWIM.Status(fromProto: proto.status)
//        self.init(peer: peer, status: status, protocolPeriod: 0) // FIXME: why this?
//    }
// }
//
// extension SWIM.PingResponse: ProtobufRepresentable {
//    public typealias ProtobufRepresentation = ProtoSWIMPingResponse
//
//    public func toProto() throws -> ProtoSWIMPingResponse {
//        var proto = ProtoSWIMPingResponse()
//        switch self {
//        case .ack(let target, let incarnation, let payload, let sequenceNumber):
//            var ack = ProtoSWIMPingResponse.Ack()
//            ack.target = try target.toProto()
//            ack.incarnation = incarnation
//            ack.payload = try payload.toProto()
//            proto.sequenceNumber = sequenceNumber
//            proto.ack = ack
//
//        case .nack(let target, let sequenceNumber):
//            var nack = ProtoSWIMPingResponse.Nack()
//            nack.target = try target.toProto()
//            proto.nack = nack
//            proto.sequenceNumber = sequenceNumber
//
//        case .timeout:
//            throw SWIMSerializationError.notSerializable(".timeout is not to be sent as remote message, was: \(self)")
//
//        case .error:
//            throw SWIMSerializationError.notSerializable(".error is not to be sent as remote message, was: \(self)")
//        }
//        return proto
//    }
//
//    public init(fromProto proto: ProtoSWIMPingResponse) throws {
//        guard let pingResponse = proto.pingResponse else {
//            throw SWIMSerializationError.missingField("pingResponse", type: String(describing: SWIM.PingResponse.self))
//        }
//        switch pingResponse {
//        case .ack(let ack):
//            let target = try Node(fromProto: ack.target)
//            let payload = try SWIM.GossipPayload(fromProto: ack.payload)
//            let sequenceNumber = proto.sequenceNumber
//            self = .ack(target: target, incarnation: ack.incarnation, payload: payload, sequenceNumber: sequenceNumber)
//
//        case .nack(let nack):
//            let target = try Node(fromProto: nack.target)
//            let sequenceNumber = proto.sequenceNumber
//            self = .nack(target: target, sequenceNumber: sequenceNumber)
//        }
//    }
// }
