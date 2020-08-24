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
import struct Dispatch.DispatchTime
import enum Dispatch.DispatchTimeInterval

extension SWIM {
    public typealias Incarnation = UInt64
    public typealias Members = [SWIM.Member]

    /// A sequence number which can be used to associate with messages in order to establish an request/response
    /// relationship between ping/pingRequest and their corresponding ack/nack messages.
    public typealias SequenceNumber = UInt32

    // TODO: or index by just the Node?
    public typealias MembersValues = Dictionary<Node, SWIM.Member>.Values
}

extension SWIM {
    /// Message sent in reply to a `SWIM.RemoteMessage.ping`.
    ///
    /// The ack may be delivered directly in a request-response fashion between the probing and pinged members,
    /// or indirectly, as a result of a `pingReq` message.
    public enum PingResponse {
        /// - parameter target: the target of the ping; i.e. when the pinged node receives a ping, the target is "myself", and that myself should be sent back in the target field.
        /// - parameter incarnation: TODO: docs
        /// - parameter payload: TODO: docs
        case ack(target: SWIMAddressablePeer, incarnation: Incarnation, payload: GossipPayload, sequenceNumber: SWIM.SequenceNumber)

        /// - parameter target: the target of the ping; i.e. when the pinged node receives a ping, the target is "myself", and that myself should be sent back in the target field.
        /// - parameter incarnation: TODO: docs
        /// - parameter payload: TODO: docs
        case nack(target: SWIMAddressablePeer, sequenceNumber: SWIM.SequenceNumber)

        /// Used to signal a response did not arrive within the expected `timeout`.
        ///
        /// If a response for some reason produces a different error immediately rather than through a timeout,
        /// the shell should also emit a `.timeout` response and feed it into the `SWIM.Instance` as it is important for
        /// timeout adjustments that the instance makes. The instance does not need to know specifics about the reason of
        /// a response not arriving, thus they are all handled via the same timeout response rather than extra "error" responses.
        ///
        /// - parameter target: the target of the ping; i.e. when the pinged node receives a ping, the target is "myself", and that myself should be sent back in the target field.
        case timeout(target: SWIMAddressablePeer, pingRequestOrigin: SWIMAddressablePeer?, timeout: DispatchTimeInterval, sequenceNumber: SWIM.SequenceNumber)

        /// Sequence number of the initial request this is a response to.
        /// Used to pair up responses to the requests which initially caused them.
        public var sequenceNumber: SWIM.SequenceNumber {
            switch self {
            case .ack(_, _, _, let sequenceNumber):
                return sequenceNumber
            case .nack(_, let sequenceNumber):
                return sequenceNumber
            case .timeout(_, _, _, let sequenceNumber):
                return sequenceNumber
            }
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Gossip

extension SWIM {
    /// A piece of "gossip" about a specific member of the cluster.
    ///
    /// A gossip will only be spread a limited number of times, as configured by `settings.gossip.gossipedEnoughTimes(_:members:)`.
    public struct Gossip: Equatable {
        public let member: SWIM.Member
        public internal(set) var numberOfTimesGossiped: Int
    }

    /// A `GossipPayload` is used to spread gossips about members.
    public enum GossipPayload {
        case none
        case membership(SWIM.Members)
    }
}

extension SWIM.GossipPayload {
    public var isNone: Bool {
        switch self {
        case .none:
            return true
        case .membership:
            return false
        }
    }

    public var isMembership: Bool {
        switch self {
        case .none:
            return false
        case .membership:
            return true
        }
    }
}
