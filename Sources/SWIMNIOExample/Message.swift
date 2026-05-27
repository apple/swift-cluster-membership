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
import NIO
import SWIM

extension SWIM {
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
