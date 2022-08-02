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
@preconcurrency import struct Dispatch.DispatchTime

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: SWIM Member

extension SWIM {
    /// A `SWIM.Member` represents an active participant of the cluster.
    ///
    /// It associates a specific `SWIMAddressablePeer` with its `SWIM.Status` and a number of other SWIM specific state information.
    public struct Member<Peer: SWIMPeer>: Sendable {
        /// Peer reference, used to send messages to this cluster member.
        ///
        /// Can represent the "local" member as well, use `swim.isMyself` to verify if a peer is `myself`.
        public var peer: Peer

        /// `Node` of the member's `peer`.
        public var node: ClusterMembership.Node {
            self.peer.node
        }

        /// Membership status of this cluster member
        public var status: SWIM.Status

        // Period in which protocol period was this state set
        public var protocolPeriod: UInt64

        /// Indicates a _local_ point in time when suspicion was started.
        ///
        /// - Note: Only suspect members may have this value set, but having the actual field in SWIM.Member feels more natural.
        /// - Note: This value is never carried across processes, as it serves only locally triggering suspicion timeouts.
        public let localSuspicionStartedAt: DispatchTime? // could be "status updated at"?

        /// Create a new member.
        public init(peer: Peer, status: SWIM.Status, protocolPeriod: UInt64, suspicionStartedAt: DispatchTime? = nil) {
            self.peer = peer
            self.status = status
            self.protocolPeriod = protocolPeriod
            self.localSuspicionStartedAt = suspicionStartedAt
        }

        /// Convenience function for checking if a member is `SWIM.Status.alive`.
        ///
        /// - Returns: `true` if the member is alive
        public var isAlive: Bool {
            self.status.isAlive
        }

        /// Convenience function for checking if a member is `SWIM.Status.suspect`.
        ///
        /// - Returns: `true` if the member is suspect
        public var isSuspect: Bool {
            self.status.isSuspect
        }

        /// Convenience function for checking if a member is `SWIM.Status.unreachable`
        ///
        /// - Returns: `true` if the member is unreachable
        public var isUnreachable: Bool {
            self.status.isUnreachable
        }

        /// Convenience function for checking if a member is `SWIM.Status.dead`
        ///
        /// - Returns: `true` if the member is dead
        public var isDead: Bool {
            self.status.isDead
        }
    }
}

/// Manual Hashable conformance since we omit `suspicionStartedAt` from identity
extension SWIM.Member: Hashable, Equatable {
    public static func == (lhs: SWIM.Member<Peer>, rhs: SWIM.Member<Peer>) -> Bool {
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

extension SWIM.Member: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        var res = "SWIM.Member(\(self.peer), \(self.status), protocolPeriod: \(self.protocolPeriod)"
        if let suspicionStartedAt = self.localSuspicionStartedAt {
            res.append(", suspicionStartedAt: \(suspicionStartedAt)")
        }
        res.append(")")
        return res
    }

    public var debugDescription: String {
        var res = "SWIM.Member(\(String(reflecting: self.peer)), \(self.status), protocolPeriod: \(self.protocolPeriod)"
        if let suspicionStartedAt = self.localSuspicionStartedAt {
            res.append(", suspicionStartedAt: \(suspicionStartedAt)")
        }
        res.append(")")
        return res
    }
}
