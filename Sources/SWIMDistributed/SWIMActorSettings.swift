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
import Distributed
import SWIM

extension SWIMActor {
    /// Settings for the generic `SWIMActor` distributed actor shell.
    ///
    /// Use this to configure a `SWIMActor` for any `DistributedActorSystem`.
    public struct Settings: Sendable {
        /// SWIM protocol settings (probe intervals, timeouts, lifeguard, etc.).
        public var swim: SWIM.Settings

        /// The node identity that this SWIM actor represents.
        public var myself: Node

        /// Resolves a cluster node to the `SWIMActor` on that node.
        ///
        /// The host system must implement this mapping. Typically this involves
        /// resolving a well-known actor ID for the SWIM peer on the target node.
        public var resolvePeer: @Sendable (Node) -> SWIMActor?

        /// Called whenever SWIM detects a reachability change.
        ///
        /// Use this to wire SWIM events into your cluster's membership state.
        public var onMembershipChange: @Sendable (SWIM.MemberStatusChangedEvent) -> Void

        /// Creates new settings for a `SWIMActor`.
        ///
        /// - Parameters:
        ///   - swim: SWIM protocol settings.
        ///   - myself: The node identity of this actor.
        ///   - resolvePeer: Closure that maps a `Node` to the `SWIMActor`
        ///     on that node.
        ///   - onMembershipChange: Closure called when a reachability change is detected.
        public init(
            swim: SWIM.Settings,
            myself: Node,
            resolvePeer: @escaping @Sendable (Node) -> SWIMActor?,
            onMembershipChange: @escaping @Sendable (SWIM.MemberStatusChangedEvent) -> Void = { _ in }
        ) {
            self.swim = swim
            self.myself = myself
            self.resolvePeer = resolvePeer
            self.onMembershipChange = onMembershipChange
        }
    }
}
