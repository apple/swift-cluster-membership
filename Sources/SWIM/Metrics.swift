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
        let members: Gauge
        /// Number of members (alive)
        let membersAlive: Gauge
        /// Number of members (suspect)
        let membersSuspect: Gauge
        /// Number of members (unreachable)
        let membersUnreachable: Gauge
        /// Number of members (dead)
        let membersDead: Gauge

        /// Records time it takes for ping round-trips
        let roundTripTime: Timer // TODO: could do dimensions

        /// Records time it takes for (every) pingRequest round-trip
        let pingRequestResponseTimeAll: Timer
        let pingRequestResponseTimeFirst: Timer

        /// Records the incarnation of the SWIM instance.
        ///
        /// Incarnation numbers are bumped whenever the node needs to refute some gossip about itself,
        /// as such the incarnation number *growth* is an interesting indicator of cluster observation churn.
        let incarnation: Gauge

        let successfulProbeCount: Gauge

        let failedProbeCount: Gauge

        // TODO: message sizes (count and bytes)

        init(settings: SWIM.Settings) {
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
        }
    }
}
