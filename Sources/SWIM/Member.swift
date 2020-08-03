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

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: SWIM Member

extension SWIM {
    public struct Member {
        /// Peer reference, used to send messages to this cluster member.
        ///
        /// Can represent the "local" member as well, use `swim.isMyself` to verify if a peer is `myself`.
        public var peer: AddressableSWIMPeer

        /// `Node` of the member's `peer`.
        public var node: ClusterMembership.Node {
            get {
                self.peer.node
            }
            set {
                self.peer.node = newValue
            }
        }

        /// Membership status of this cluster member
        public var status: SWIM.Status

        // Period in which protocol period was this state set
        public let protocolPeriod: Int

        /// Indicates a time when suspicion was started.
        ///
        /// // FIXME: reword this paragraph
        /// Only suspicion needs to have it, but having the actual field in SWIM.Member feels more natural.
        /// Putting it inside `SWIM.Status` makes time management a huge mess: status can either be created internally in
        /// SWIM.Member or deserialized from protobuf. Having this in SWIM.Member ensures we never pass it on the wire and we can't make a mistake when merging suspicions.
        public let suspicionStartedAt: Int64?

        public init(peer: AddressableSWIMPeer, status: SWIM.Status, protocolPeriod: Int, suspicionStartedAt: Int64? = nil) {
            self.peer = peer
            self.status = status
            self.protocolPeriod = protocolPeriod
            self.suspicionStartedAt = suspicionStartedAt
        }

        public var isAlive: Bool {
            self.status.isAlive
        }

        public var isSuspect: Bool {
            self.status.isSuspect
        }

        public var isUnreachable: Bool {
            self.status.isUnreachable
        }

        public var isDead: Bool {
            self.status.isDead
        }
    }
}

/// Manual Hashable conformance since we omit suspicionStartedAt from identity
extension SWIM.Member: Hashable, Equatable {
    public static func == (lhs: SWIM.Member, rhs: SWIM.Member) -> Bool {
        lhs.peer.node == rhs.peer.node &&
            lhs.protocolPeriod == rhs.protocolPeriod &&
            lhs.status == rhs.status
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(self.peer.node)
        hasher.combine(self.protocolPeriod)
        hasher.combine(self.status)
    }
}
