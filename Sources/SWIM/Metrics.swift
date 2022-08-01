//===----------------------------------------------------------------------===//
//
// This source file is part of the swift-cluster-membership open source project
//
// Copyright (c) 2020 Apple Inc. and the swift-cluster-membership project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of swift-cluster-membership project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Metrics

extension SWIM {
    /// Object containing all metrics a SWIM instance and shell should be reporting.
    ///
    /// - SeeAlso: `SWIM.Metrics.Shell` for metrics that a specific implementation should emit
    public struct Metrics {
        // ==== --------------------------------------------------------------------------------------------------------
        // MARK: Membership

        /// Number of members (alive)
        public let membersAlive: Gauge
        /// Number of members (suspect)
        public let membersSuspect: Gauge
        /// Number of members (unreachable)
        public let membersUnreachable: Gauge
        // Number of members (dead) is not reported, because "dead" is considered "removed" from the cluster
        // -- no metric --

        /// Total number of nodes *ever* declared noticed as dead by this member
        public let membersTotalDead: Counter

        /// The current number of tombstones for previously known (and now dead and removed) members.
        public let removedDeadMemberTombstones: Gauge

        // ==== --------------------------------------------------------------------------------------------------------
        // MARK: Internal metrics

        /// Current value of the local health multiplier.
        public let localHealthMultiplier: Gauge

        // ==== --------------------------------------------------------------------------------------------------------
        // MARK: Probe metrics

        /// Records the incarnation of the SWIM instance.
        ///
        /// Incarnation numbers are bumped whenever the node needs to refute some gossip about itself,
        /// as such the incarnation number *growth* is an interesting indicator of cluster observation churn.
        public let incarnation: Gauge

        /// Total number of successful probes (pings with successful replies)
        public let successfulPingProbes: Counter
        /// Total number of failed probes (pings with successful replies)
        public let failedPingProbes: Counter

        /// Total number of successful ping request probes (pingRequest with successful replies)
        /// Either an .ack or .nack from the intermediary node count as an success here
        public let successfulPingRequestProbes: Counter
        /// Total number of failed ping request probes (pings requests with successful replies)
        /// Only a .timeout counts as a failed ping request.
        public let failedPingRequestProbes: Counter

        // ==== ----------------------------------------------------------------------------------------------------------------
        // MARK: Shell / Transport Metrics

        /// Metrics to be filled in by respective SWIM shell implementations.
        public let shell: ShellMetrics

        public struct ShellMetrics {
            // ==== ----------------------------------------------------------------------------------------------------
            // MARK: Probe metrics

            /// Records time it takes for ping successful round-trips.
            public let pingResponseTime: Timer

            /// Records time it takes for (every) successful pingRequest round-trip
            public let pingRequestResponseTimeAll: Timer
            /// Records the time it takes for the (first) successful pingRequest to round trip
            /// (A ping request hits multiple intermediary peers, the first reply is what counts)
            public let pingRequestResponseTimeFirst: Timer

            /// Number of incoming messages received
            public let messageInboundCount: Counter
            /// Sizes of messages received, in bytes
            public let messageInboundBytes: Recorder

            /// Number of messages sent
            public let messageOutboundCount: Counter
            /// Sizes of messages sent, in bytes
            public let messageOutboundBytes: Recorder

            public init(settings: SWIM.Settings) {
                self.pingResponseTime = Timer(
                    label: settings.metrics.makeLabel("roundTripTime", "ping")
                )

                self.pingRequestResponseTimeAll = Timer(
                    label: settings.metrics.makeLabel("roundTripTime", "pingRequest"),
                    dimensions: [("type", "all")]
                )
                self.pingRequestResponseTimeFirst = Timer(
                    label: settings.metrics.makeLabel("roundTripTime", "pingRequest"),
                    dimensions: [("type", "firstAck")]
                )

                self.messageInboundCount = Counter(
                    label: settings.metrics.makeLabel("message", "count"),
                    dimensions: [
                        ("direction", "in"),
                    ]
                )
                self.messageInboundBytes = Recorder(
                    label: settings.metrics.makeLabel("message", "bytes"),
                    dimensions: [
                        ("direction", "in"),
                    ]
                )

                self.messageOutboundCount = Counter(
                    label: settings.metrics.makeLabel("message", "count"),
                    dimensions: [
                        ("direction", "out"),
                    ]
                )
                self.messageOutboundBytes = Recorder(
                    label: settings.metrics.makeLabel("message", "bytes"),
                    dimensions: [
                        ("direction", "out"),
                    ]
                )
            }
        }

        public init(settings: SWIM.Settings) {
            self.membersAlive = Gauge(
                label: settings.metrics.makeLabel("members"),
                dimensions: [("status", "alive")]
            )
            self.membersSuspect = Gauge(
                label: settings.metrics.makeLabel("members"),
                dimensions: [("status", "suspect")]
            )
            self.membersUnreachable = Gauge(
                label: settings.metrics.makeLabel("members"),
                dimensions: [("status", "unreachable")]
            )
            self.membersTotalDead = Counter(
                label: settings.metrics.makeLabel("members", "total"),
                dimensions: [("status", "dead")]
            )
            self.removedDeadMemberTombstones = Gauge(
                label: settings.metrics.makeLabel("removedMemberTombstones")
            )

            self.localHealthMultiplier = Gauge(
                label: settings.metrics.makeLabel("lha")
            )

            self.incarnation = Gauge(label: settings.metrics.makeLabel("incarnation"))

            self.successfulPingProbes = Counter(
                label: settings.metrics.makeLabel("probe", "ping"),
                dimensions: [("type", "successful")]
            )
            self.failedPingProbes = Counter(
                label: settings.metrics.makeLabel("probe", "ping"),
                dimensions: [("type", "failed")]
            )

            self.successfulPingRequestProbes = Counter(
                label: settings.metrics.makeLabel("probe", "pingRequest"),
                dimensions: [("type", "successful")]
            )
            self.failedPingRequestProbes = Counter(
                label: settings.metrics.makeLabel("probe", "pingRequest"),
                dimensions: [("type", "failed")]
            )

            self.shell = .init(settings: settings)
        }
    }
}

extension SWIM.Metrics {
    /// Update member metrics metrics based on SWIM's membership.
    public func updateMembership(_ members: SWIM.Membership<some SWIMPeer>) {
        var alives = 0
        var suspects = 0
        var unreachables = 0
        for member in members {
            switch member.status {
            case .alive:
                alives += 1
            case .suspect:
                suspects += 1
            case .unreachable:
                unreachables += 1
            case .dead:
                () // dead is reported as a removal when they're removed and tombstoned, not as a gauge
            }
        }
        self.membersAlive.record(alives)
        self.membersSuspect.record(suspects)
        self.membersUnreachable.record(unreachables)
    }
}
