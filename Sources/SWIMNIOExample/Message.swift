//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Cluster Membership open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift Cluster Membership project authors
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

extension SWIM {
    /// Local (in-process) messages for interacting with a SWIM shell.
    public enum LocalMessage: Sendable {
        /// Requests SWIM to start monitoring a node.
        ///
        /// Causes an initial ping to be sent to the node, with retries until the node becomes a member.
        case monitor(Node)

        /// Marks a node as confirmed `.dead`.
        ///
        /// Updates the local SWIM instance's failure detection and gossip state.
        /// If the node was not previously known, the request is ignored.
        case confirmDead(Node)
    }

    /// Wire messages exchanged between SWIM peers.
    public enum Message: Sendable {
        /// A periodic health-check probe sent to a randomly selected peer.
        ///
        /// The recipient must reply with an `.ack` (via `.response(.ack(...))`) directed
        /// back to the `replyTo` node. If no reply arrives within the probe timeout,
        /// the origin should treat it as a timeout and may escalate to indirect probes
        /// via `.pingRequest`.
        case ping(replyTo: Node, payload: GossipPayload, sequenceNumber: SWIM.SequenceNumber)

        /// An indirect probe request sent to an intermediary peer, asking it to ping
        /// `target` on our behalf.
        ///
        /// The intermediary should forward the result back to `replyTo`:
        /// - If the target responds, forward its `.ack`.
        /// - If the target does not respond in time, the intermediary MAY send a `.nack`
        ///   back to `replyTo` so the origin knows the intermediary itself is still alive.
        case pingRequest(
            target: Node,
            replyTo: Node,
            payload: GossipPayload,
            sequenceNumber: SWIM.SequenceNumber
        )

        /// A response to a `.ping` or `.pingRequest`: either an `ack`, a `nack`, or a `timeout`.
        case response(PingResponse)

        var messageCaseDescription: String {
            switch self {
            case .ping(_, _, let nr):
                return "ping@\(nr)"
            case .pingRequest(_, _, _, let nr):
                return "pingRequest@\(nr)"
            case .response(.ack(_, _, _, let nr)):
                return "response/ack@\(nr)"
            case .response(.nack(_, let nr)):
                return "response/nack@\(nr)"
            case .response(.timeout(_, _, _, let nr)):
                return "response/timeout@\(nr)"
            }
        }

        public var sequenceNumber: SWIM.SequenceNumber {
            switch self {
            case .ping(_, _, let sequenceNumber):
                return sequenceNumber
            case .pingRequest(_, _, _, let sequenceNumber):
                return sequenceNumber
            case .response(.ack(_, _, _, let sequenceNumber)):
                return sequenceNumber
            case .response(.nack(_, let sequenceNumber)):
                return sequenceNumber
            case .response(.timeout(_, _, _, let sequenceNumber)):
                return sequenceNumber
            }
        }

        public var isResponse: Bool {
            if case .response = self {
                return true
            }
            return false
        }
    }
}

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
            let replyTo = try container.decode(Node.self, forKey: .replyTo)
            let payload = try container.decode(SWIM.GossipPayload.self, forKey: .payload)
            let sequenceNumber = try container.decode(SWIM.SequenceNumber.self, forKey: .sequenceNumber)
            self = .ping(replyTo: replyTo, payload: payload, sequenceNumber: sequenceNumber)

        case .pingRequest:
            let target = try container.decode(Node.self, forKey: .target)
            let replyTo = try container.decode(Node.self, forKey: .replyTo)
            let payload = try container.decode(SWIM.GossipPayload.self, forKey: .payload)
            let sequenceNumber = try container.decode(SWIM.SequenceNumber.self, forKey: .sequenceNumber)
            self = .pingRequest(target: target, replyTo: replyTo, payload: payload, sequenceNumber: sequenceNumber)

        case .response_ack:
            let target = try container.decode(Node.self, forKey: .target)
            let incarnation = try container.decode(SWIM.Incarnation.self, forKey: .incarnation)
            let payload = try container.decode(SWIM.GossipPayload.self, forKey: .payload)
            let sequenceNumber = try container.decode(SWIM.SequenceNumber.self, forKey: .sequenceNumber)
            self = .response(
                .ack(target: target, incarnation: incarnation, payload: payload, sequenceNumber: sequenceNumber)
            )

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
