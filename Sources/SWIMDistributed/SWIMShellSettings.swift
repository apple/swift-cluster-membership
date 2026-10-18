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

extension SWIM.Shell {
    /// Settings for `SWIM.Shell`.
    ///
    /// Use this to configure a `SWIM.Shell` for any `DistributedActorSystem`.
    public struct Settings: Sendable {
        /// SWIM protocol settings (probe intervals, timeouts, lifeguard, etc.).
        public var swim: SWIM.Settings

        /// The node identity that this SWIM actor represents.
        public var myself: Node

        /// Resolves a cluster node to the `SWIM.Shell` on that node.
        ///
        /// The host system must implement this mapping. Typically this involves
        /// resolving a well-known actor ID for the SWIM peer on the target node.
        public var resolvePeer: @Sendable (Node) async -> SWIM.Shell<System>?

        /// Creates new settings for a `SWIM.Shell`.
        ///
        /// - Parameters:
        ///   - swim: SWIM protocol settings.
        ///   - myself: The node identity of this actor.
        ///   - resolvePeer: Closure that maps a `Node` to the `SWIM.Shell`
        ///     on that node.
        public init(
            swim: SWIM.Settings,
            myself: Node,
            resolvePeer: @escaping @Sendable (Node) async -> SWIM.Shell<System>?
        ) {
            self.swim = swim
            self.myself = myself
            self.resolvePeer = resolvePeer
        }
    }
}
