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

/// To make generated SWIM.pb.swift happy
public typealias ProtoPeer = ClusterMembership.ProtoPeer
public typealias ProtoNode = ClusterMembership.ProtoNode

extension SWIM.Message: InternalProtobufRepresentable {
    typealias ProtobufRepresentation = ProtoSWIMRemoteMessage

    public func toProto() throws -> ProtobufRepresentation {
        guard case SWIM.Message.remote(let message) = self else {
            fatalError("SWIM.Message.local should never be sent remotely.")
        }

        return try message.toProto()
    }

    public init(fromProto proto: ProtobufRepresentation) throws {
        self = try .remote(SWIM.RemoteMessage(fromProto: proto))
    }
}

extension SWIM.RemoteMessage: InternalProtobufRepresentable {
    typealias ProtobufRepresentation = ProtoSWIMRemoteMessage

    public func toProto() throws -> ProtobufRepresentation {
        var proto = ProtobufRepresentation()
        switch self {
        case .ping(let replyTo, let payload):
            var ping = ProtoSWIMPing()
            ping.replyTo = try replyTo.toProto()
            ping.payload = try payload.toProto()
            proto.ping = ping
        case .pingReq(let target, let replyTo, let payload):
            var pingRequest = ProtoSWIMPingRequest()
            pingRequest.target = try target.toProto()
            pingRequest.replyTo = try replyTo.toProto()
            pingRequest.payload = try payload.toProto()
            proto.pingRequest = pingRequest
        }

        return proto
    }

    public init(fromProto proto: ProtobufRepresentation) throws {
        switch proto.request {
        case .ping(let ping):
            let replyTo = try Peer<SWIM.PingResponse>(fromProto: ping.replyTo)
            let payload = try SWIM.GossipPayload(fromProto: ping.payload)
            self = .ping(replyTo: replyTo, payload: payload)
        case .pingRequest(let pingRequest):
            let target = try Peer<SWIM.Message>(fromProto: pingRequest.target)
            let replyTo = try Peer<SWIM.PingResponse>(fromProto: pingRequest.replyTo)
            let payload = try SWIM.GossipPayload(fromProto: pingRequest.payload)
            self = .pingReq(target: target, replyTo: replyTo, payload: payload)
        case .none:
            throw SWIMSerializationError.missingField("request", type: String(describing: SWIM.Message.self))
        }
    }
}

extension SWIM.Status: InternalProtobufRepresentable {
    typealias ProtobufRepresentation = ProtoSWIMStatus

    func toProto() throws -> ProtoSWIMStatus {
        var proto = ProtoSWIMStatus()
        switch self {
        case .alive(let incarnation):
            proto.type = .alive
            proto.incarnation = incarnation
        case .suspect(let incarnation, let suspectedBy):
            proto.type = .suspect
            proto.incarnation = incarnation
            proto.suspectedBy = try suspectedBy.map { try $0.toProto() }
        case .unreachable(let incarnation):
            proto.type = .unreachable
            proto.incarnation = incarnation
        case .dead:
            proto.type = .dead
            proto.incarnation = 0
        }

        return proto
    }

    init(fromProto proto: ProtoSWIMStatus) throws {
        switch proto.type {
        case .alive:
            self = .alive(incarnation: proto.incarnation)
        case .suspect:
            let suspectedBy = try Set(proto.suspectedBy.map { try Node(fromProto: $0) })
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

extension SWIM.GossipPayload: InternalProtobufRepresentable {
    typealias ProtobufRepresentation = ProtoSWIMPayload

    func toProto() throws -> ProtoSWIMPayload {
        var payload = ProtoSWIMPayload()
        if case .membership(let members) = self {
            payload.member = try members.map { try $0.toProto() }
        }

        return payload
    }

    init(fromProto proto: ProtoSWIMPayload) throws {
        if proto.member.isEmpty {
            self = .none
        } else {
            let members = try proto.member.map { proto in try SWIM.Member(fromProto: proto) }
            self = .membership(members)
        }
    }
}

extension SWIM.Member: InternalProtobufRepresentable {
    typealias ProtobufRepresentation = ProtoSWIMMember

    func toProto() throws -> ProtoSWIMMember {
        var proto = ProtoSWIMMember()
        proto.node = try self.peer.toProto()
        proto.status = try self.status.toProto()
        return proto
    }

    init(fromProto proto: ProtoSWIMMember) throws {
        let address = try PeerAddress(fromProto: proto.node)
        let peer = context.resolvePeer(SWIM.Message.self, identifiedBy: address)
        let status = try SWIM.Status(fromProto: proto.status)
        self.init(peer: peer, status: status, protocolPeriod: 0) // FIXME: is this 0 correct?
    }
}

extension SWIM.PingResponse: InternalProtobufRepresentable {
    typealias ProtobufRepresentation = ProtoSWIMPingResponse

    func toProto() throws -> ProtoSWIMPingResponse {
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
        }
        return proto
    }

    init(fromProto proto: ProtoSWIMPingResponse) throws {
        guard let pingResponse = proto.pingResponse else {
            throw SWIMSerializationError.missingField("pingResponse", type: String(describing: SWIM.PingResponse.self))
        }
        switch pingResponse {
        case .ack(let ack):
            let target = context.resolvePeer(SWIM.Message.self, identifiedBy: try PeerAddress(fromProto: ack.target))
            let payload = try SWIM.GossipPayload(fromProto: ack.payload)
            self = .ack(target: target, incarnation: ack.incarnation, payload: payload)
        case .nack(let nack):
            let target = context.resolvePeer(SWIM.Message.self, identifiedBy: try PeerAddress(fromProto: nack.target))
            self = .nack(target: target)
        }
    }
}
