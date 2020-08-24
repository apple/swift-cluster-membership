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

/// Namespace for SWIMNIO constants.
public enum SWIMNIO {}

extension SWIMNIO {
    /// SWIMNIO specific settings.
    public struct Settings {
        /// Underlying settings for the SWIM protocol implementation.
        public var swim: SWIM.Settings

        public init() {
            self.init(swim: .init())
        }

        public init(swim: SWIM.Settings) {
            self.swim = swim
            self.logger = swim.logger
        }

        /// The node as which this SWIMNIO shell should be bound.
        ///
        /// - SeeAlso: `SWIM.Settings.node`
        public var node: Node? {
            get {
                self.swim.node
            }
            set {
                self.swim.node = newValue
            }
        }

        // ==== Settings specific to SWIMNIO ---------------------------------------------------------------------------

        /// Allows for customizing the used logger.
        /// By default the same as passed in `swim.logger` in the initializer is used.
        public var logger: Logger

        // TODO: retry initial contact points max count: https://github.com/apple/swift-cluster-membership/issues/32

        /// How frequently the shell should retry attempting to join a `swim.initialContactPoint`
        public var initialContactPointPingInterval: TimeAmount = .seconds(5)

        /// For testing only, as it effectively disables the swim protocol period ticks.
        ///
        /// Allows for disabling of the periodically scheduled protocol period ticks.
        internal var _startPeriodicPingTimer: Bool = true
    }
}
