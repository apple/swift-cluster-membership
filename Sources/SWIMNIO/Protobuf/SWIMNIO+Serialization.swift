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

/// To make generated SWIM.pb.swift happy
public typealias ProtoPeer = ClusterMembership.ProtoPeer
public typealias ProtoNode = ClusterMembership.ProtoNode

extension SWIM.NIOPeer: ProtobufRepresentable {
    public typealias ProtobufRepresentation = ProtoPeer

    public func toProto() throws -> ProtobufRepresentation {
        var proto = ProtoPeer()
        proto.node = try self.node.toProto()
        return proto
    }

    public init(fromProto proto: ProtobufRepresentation) throws {
        self.init(node: try .init(fromProto: proto.node), channel: nil)
        // self.channel = nil // FIXME: somewhat annoying; should we get it from somewhere like the context...? not to rely on the ensureChannel()
    }
}

extension SWIM.Message: ProtobufRepresentable {
    public typealias ProtobufRepresentation = ProtoSWIMMessage

    public func toProto() throws -> ProtobufRepresentation {
        var proto = ProtobufRepresentation()
        switch self {
        case .ping(let replyTo, let payload, let sequenceNr):
            var ping = ProtoSWIMPing()
            ping.replyTo = try replyTo.toProto()
            ping.payload = try payload.toProto()
            proto.sequenceNr = sequenceNr
            proto.ping = ping

        case .pingReq(let target, let replyTo, let payload, let sequenceNr):
            var pingRequest = ProtoSWIMPingRequest()
            pingRequest.target = try target.toProto()
            pingRequest.replyTo = try replyTo.toProto()
            pingRequest.payload = try payload.toProto()
            proto.sequenceNr = sequenceNr
            proto.pingReq = pingRequest

        case .response(let response, let sequenceNr):
            proto.sequenceNr = sequenceNr
            proto.response = try response.toProto()
        }

        return proto
    }

    public init(fromProto proto: ProtobufRepresentation) throws {
        switch proto.message {
        case .ping(let ping):
            let replyTo = try SWIM.NIOPeer(fromProto: ping.replyTo)
            let payload = try SWIM.GossipPayload(fromProto: ping.payload)
            let sequenceNr = proto.sequenceNr
            self = .ping(replyTo: replyTo, payload: payload, sequenceNr: sequenceNr)

        case .pingReq(let pingRequest):
            let target = try SWIM.NIOPeer(fromProto: pingRequest.target)
            let replyTo = try SWIM.NIOPeer(fromProto: pingRequest.replyTo)
            let payload = try SWIM.GossipPayload(fromProto: pingRequest.payload)
            let sequenceNr = proto.sequenceNr
            self = .pingReq(target: target, replyTo: replyTo, payload: payload, sequenceNr: sequenceNr)

        case .response(let response):
            switch response.pingResponse {
            case .ack:
                guard response.ack.hasTarget else {
                    throw SWIMSerializationError.missingField("target", type: "\(type(of: Node.self))")
                }
                let target: Node = try .init(fromProto: response.ack.target)
                let incarnation: UInt64 = response.ack.incarnation
                let payload: SWIM.GossipPayload
                if response.ack.hasPayload {
                    payload = try .init(fromProto: response.ack.payload)
                } else {
                    payload = .none
                }
                let sequenceNr = proto.sequenceNr
                self = .response(.ack(target: target, incarnation: incarnation, payload: payload), sequenceNr: sequenceNr)

            case .nack:
                guard response.nack.hasTarget else {
                    throw SWIMSerializationError.missingField("target", type: "\(type(of: Node.self))")
                }
                let target: Node = try .init(fromProto: response.nack.target)
                let sequenceNr = proto.sequenceNr
                self = .response(.nack(target: target), sequenceNr: sequenceNr)

            case .none:
                throw SWIMSerializationError.missingField("response", type: "PingResponse")
            }

        case .none:
            throw SWIMSerializationError.missingField("request", type: String(describing: SWIM.Message.self))
        }
    }
}

extension SWIM.Status: ProtobufRepresentable {
    public typealias ProtobufRepresentation = ProtoSWIMStatus

    public func toProto() throws -> ProtoSWIMStatus {
        var proto = ProtoSWIMStatus()
        switch self {
        case .alive(let incarnation):
            proto.type = .alive
            proto.incarnation = incarnation
        case .suspect(let incarnation, let suspectedBy):
            proto.type = .suspect
            proto.incarnation = incarnation
            proto.suspectedBy = try suspectedBy.map {
                try $0.toProto()
            }
        case .unreachable(let incarnation):
            proto.type = .unreachable
            proto.incarnation = incarnation
        case .dead:
            proto.type = .dead
            proto.incarnation = 0
        }

        return proto
    }

    public init(fromProto proto: ProtoSWIMStatus) throws {
        switch proto.type {
        case .alive:
            self = .alive(incarnation: proto.incarnation)
        case .suspect:
            let suspectedBy = try Set(proto.suspectedBy.map {
                try Node(fromProto: $0)
            })
            self = .suspect(incarnation: proto.incarnation, suspectedBy: suspectedBy)
        case .unreachable:
            self = .unreachable(incarnation: proto.incarnation)
        case .dead:
            self = .dead
        case .unspecified:
            throw SWIMSerializationError.missingField("type", type: String(describing: SWIM.Status.self))
        case .UNRECOGNIZED(let num):
            throw SWIMSerializationError.unknownEnumValue(num)
        }
    }
}

extension SWIM.GossipPayload: ProtobufRepresentable {
    public typealias ProtobufRepresentation = ProtoSWIMPayload

    public func toProto() throws -> ProtoSWIMPayload {
        var payload = ProtoSWIMPayload()
        if case .membership(let members) = self {
            payload.members = try members.map {
                try $0.toProto()
            }
        }

        return payload
    }

    public init(fromProto proto: ProtoSWIMPayload) throws {
        if proto.members.isEmpty {
            self = .none
        } else {
            let members = try proto.members.map { proto in
                try SWIM.Member(fromProto: proto)
            }
            self = .membership(members)
        }
    }
}

extension SWIM.Member: ProtobufRepresentable {
    public typealias ProtobufRepresentation = ProtoSWIMMember

    public func toProto() throws -> ProtoSWIMMember {
        var proto = ProtoSWIMMember()
        guard let nioPeer = self.peer as? SWIM.NIOPeer else {
            fatalError("Can only support `NIOPeer`s, was: \(self.peer)")
        }
        proto.peer = try nioPeer.toProto()
        proto.status = try self.status.toProto()
        return proto
    }

    public init(fromProto proto: ProtoSWIMMember) throws {
        let peer = try SWIM.NIOPeer(fromProto: proto.peer)
        let status = try SWIM.Status(fromProto: proto.status)
        self.init(peer: peer, status: status, protocolPeriod: 0) // FIXME: why this?
    }
}

extension SWIM.PingResponse: ProtobufRepresentable {
    public typealias ProtobufRepresentation = ProtoSWIMPingResponse

    public func toProto() throws -> ProtoSWIMPingResponse {
        var proto = ProtoSWIMPingResponse()
        switch self {
        case .ack(let target, let incarnation, let payload):
            var ack = ProtoSWIMPingResponse.Ack()
            ack.target = try target.toProto()
            ack.incarnation = incarnation
            ack.payload = try payload.toProto()
            proto.ack = ack

        case .nack(let target):
            var nack = ProtoSWIMPingResponse.Nack()
            nack.target = try target.toProto()
            proto.nack = nack

        case .timeout:
            throw SWIMSerializationError.notSerializable(".timeout is not to be sent as remote message, was: \(self)")

        case .error:
            throw SWIMSerializationError.notSerializable(".error is not to be sent as remote message, was: \(self)")
        }
        return proto
    }

    public init(fromProto proto: ProtoSWIMPingResponse) throws {
        guard let pingResponse = proto.pingResponse else {
            throw SWIMSerializationError.missingField("pingResponse", type: String(describing: SWIM.PingResponse.self))
        }
        switch pingResponse {
        case .ack(let ack):
            let target = try Node(fromProto: ack.target)
            let payload = try SWIM.GossipPayload(fromProto: ack.payload)
            self = .ack(target: target, incarnation: ack.incarnation, payload: payload)

        case .nack(let nack):
            let target = try Node(fromProto: nack.target)
            self = .nack(target: target)
        }
    }
}
