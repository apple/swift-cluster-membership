//===----------------------------------------------------------------------===//
//
// This source file is part of the swift-cluster-membership open source project
//
// Copyright (c) 2018 Apple Inc. and the swift-cluster-membership project authors
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
    public struct Metrics {
        /// Number of members (total)
        public let members: Gauge
        /// Number of members (alive)
        public let membersAlive: Gauge
        /// Number of members (suspect)
        public let membersSuspect: Gauge
        /// Number of members (unreachable)
        public let membersUnreachable: Gauge
        /// Number of members (dead)
        public let membersDead: Gauge

        /// Records time it takes for ping round-trips
        public let roundTripTime: Timer // TODO: could do dimensions

        /// Records time it takes for (every) pingRequest round-trip
        public let pingRequestResponseTimeAll: Timer
        public let pingRequestResponseTimeFirst: Timer

        /// Records the incarnation of the SWIM instance.
        ///
        /// Incarnation numbers are bumped whenever the node needs to refute some gossip about itself,
        /// as such the incarnation number *growth* is an interesting indicator of cluster observation churn.
        public let incarnation: Gauge

        public let successfulProbeCount: Gauge

        public let failedProbeCount: Gauge

        // TODO: message sizes (count and bytes)
        public let messageCountInbound: Counter
        public let messageBytesInbound: Recorder

        public let messageCountOutbound: Counter
        public let messageBytesOutbound: Recorder

        public init(settings: SWIM.Settings) {
            self.members = Gauge(
                label: settings.metrics.makeLabel("members"),
                dimensions: [("status", "all")]
            )
            self.membersAlive = Gauge(
                label: settings.metrics.makeLabel("members"),
                dimensions: [("status", "alive")]
            )
            self.membersSuspect = Gauge(
                label: settings.metrics.makeLabel("members"),
                dimensions: [("status", "dead")]
            )
            self.membersUnreachable = Gauge(
                label: settings.metrics.makeLabel("members"),
                dimensions: [("status", "unreachable")]
            )
            self.membersDead = Gauge(
                label: settings.metrics.makeLabel("members"),
                dimensions: [("status", "dead")]
            )

            self.roundTripTime = Timer(label: settings.metrics.makeLabel("responseRoundTrip", "ping"))
            self.pingRequestResponseTimeAll = Timer(
                label: settings.metrics.makeLabel("responseRoundTrip", "pingRequest"),
                dimensions: [("type", "all")]
            )
            self.pingRequestResponseTimeFirst = Timer(
                label: settings.metrics.makeLabel("responseRoundTrip", "pingRequest"),
                dimensions: [("type", "firstSuccessful")]
            )
            self.incarnation = Gauge(label: settings.metrics.makeLabel("incarnation"))

            self.successfulProbeCount = Gauge(
                label: settings.metrics.makeLabel("incarnation"),
                dimensions: [("type", "successful")]
            )
            self.failedProbeCount = Gauge(
                label: settings.metrics.makeLabel("incarnation"),
                dimensions: [("type", "failed")]
            )

            // TODO: how to best design the labels?
            self.messageCountInbound = Counter(
                label: settings.metrics.makeLabel("message"),
                dimensions: [
                    ("type", "count"),
                    ("direction", "in"),
                ]
            )
            self.messageBytesInbound = Recorder(
                label: settings.metrics.makeLabel("message"),
                dimensions: [
                    ("type", "bytes"),
                    ("direction", "in"),
                ]
            )

            self.messageCountOutbound = Counter(
                label: settings.metrics.makeLabel("message"),
                dimensions: [
                    ("type", "count"),
                    ("direction", "out"),
                ]
            )
            self.messageBytesOutbound = Recorder(
                label: settings.metrics.makeLabel("message"),
                dimensions: [
                    ("type", "bytes"),
                    ("direction", "out"),
                ]
            )
        }
    }
}

extension SWIM.Metrics {
    /// Update member metrics metrics based on SWIM's membership.
    public func updateMembership(_ members: SWIM.Membership) {
        var alives = 0
        var suspects = 0
        var unreachables = 0
        var deads = 0
        for member in members {
            switch member.status {
            case .alive:
                alives += 1
            case .suspect:
                suspects += 1
            case .unreachable:
                unreachables += 1
            case .dead:
                deads += 1
            }
        }
        self.membersAlive.record(alives)
        self.membersSuspect.record(suspects)
        self.membersUnreachable.record(unreachables)
        self.membersDead.record(deads)
    }
}
