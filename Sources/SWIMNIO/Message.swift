//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Cluster Membership open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift Cluster Membership project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Cluster Membership project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import ClusterMembership
import Logging
import NIO
import SWIM

extension SWIM {
    public enum Message {
        case ping(replyTo: NIOPeer, payload: GossipPayload, sequenceNumber: SWIM.SequenceNumber)

        /// "Ping Request" requests a SWIM probe.
        case pingRequest(target: NIOPeer, replyTo: NIOPeer, payload: GossipPayload, sequenceNumber: SWIM.SequenceNumber)

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
            case .response(.error(_, _, let nr)):
                // not a "real message"
                return "response/error@\(nr)"
            case .response(.timeout(_, _, _, let nr)):
                // not a "real message"
                return "response/timeout@\(nr)"
            }
        }

        /// Responses are special treated, i.e. they may trigger a pending completion closure
        var isResponse: Bool {
            switch self {
            case .response:
                return true
            default:
                return false
            }
        }

        var sequenceNumber: SWIM.SequenceNumber {
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
            case .response(.error(_, _, let sequenceNumber)):
                return sequenceNumber
            }
        }
    }
}
