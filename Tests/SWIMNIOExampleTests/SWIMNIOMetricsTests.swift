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
import Metrics
import NIO
import SWIMTestKit
import Synchronization
import Testing

@testable import CoreMetrics
@testable import SWIM
@testable import SWIMNIOExample

@Suite(.serialized)
final class SWIMNIOMetricsTests {
    var testMetrics: TestMetrics!
    let realClustered = RealClustered()

    init() {
        self.testMetrics = TestMetrics()
        MetricsSystem.bootstrapInternal(self.testMetrics)
    }

    deinit {
        MetricsSystem.bootstrapInternal(NOOPMetricsHandler.instance)
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Metrics tests
    @Test
    func test_metrics_emittedByNIOImplementation() async throws {
        let (firstHandler, _) = self.realClustered.makeClusterNode { settings in
            settings.swim.metrics.labelPrefix = "first"
            settings.swim.probeInterval = .milliseconds(100)
        }
        _ = self.realClustered.makeClusterNode { settings in
            settings.swim.metrics.labelPrefix = "second"
            settings.swim.probeInterval = .milliseconds(100)
            settings.swim.initialContactPoints = [firstHandler.shell.node]
        }
        let (_, thirdChannel) = self.realClustered.makeClusterNode { settings in
            settings.swim.metrics.labelPrefix = "third"
            settings.swim.probeInterval = .milliseconds(100)
            settings.swim.initialContactPoints = [firstHandler.shell.node]
        }

        try await Task.sleep(for: .seconds(1))  // giving it some extra time to report a few metrics (a few round-trip times etc).

        let m: SWIM.Metrics.ShellMetrics = firstHandler.metrics!

        let roundTripTime = try! self.testMetrics.expectTimer(m.pingResponseTime)
        #expect(roundTripTime.lastValue != nil)  // some roundtrip time should have been reported
        for rtt in roundTripTime.values {
            print("  ping rtt recorded: \(TimeAmount.nanoseconds(rtt).prettyDescription)")
        }

        let messageInboundCount = try! self.testMetrics.expectCounter(m.messageInboundCount)
        let messageInboundBytes = try! self.testMetrics.expectRecorder(m.messageInboundBytes)
        print("  messageInboundCount = \(messageInboundCount.totalValue)")
        print("  messageInboundBytes = \(messageInboundBytes.lastValue!)")
        #expect(messageInboundCount.totalValue > 0)
        #expect(messageInboundBytes.lastValue! > 0)

        let messageOutboundCount = try! self.testMetrics.expectCounter(m.messageOutboundCount)
        let messageOutboundBytes = try! self.testMetrics.expectRecorder(m.messageOutboundBytes)
        print("  messageOutboundCount = \(messageOutboundCount.totalValue)")
        print("  messageOutboundBytes = \(messageOutboundBytes.lastValue!)")
        #expect(messageOutboundCount.totalValue > 0)
        #expect(messageOutboundBytes.lastValue! > 0)

        thirdChannel.close(promise: nil)
        try await Task.sleep(for: .seconds(2))

        let pingRequestResponseTimeAll = try! self.testMetrics.expectTimer(m.pingRequestResponseTimeAll)
        print("  pingRequestResponseTimeAll = \(pingRequestResponseTimeAll.lastValue!)")
        #expect(pingRequestResponseTimeAll.lastValue! > 0)

        let pingRequestResponseTimeFirst = try! self.testMetrics.expectTimer(m.pingRequestResponseTimeFirst)
        #expect(pingRequestResponseTimeFirst.lastValue == nil)  // because this only counts ACKs, and we get NACKs because the peer is down

        let successfulPingProbes = try! self.testMetrics.expectCounter(
            firstHandler.shell.swim.metrics.successfulPingProbes
        )
        print("  successfulPingProbes = \(successfulPingProbes.totalValue)")
        #expect(successfulPingProbes.totalValue > 1)  // definitely at least one, we joined some nodes

        let failedPingProbes = try! self.testMetrics.expectCounter(firstHandler.shell.swim.metrics.failedPingProbes)
        print("  failedPingProbes = \(failedPingProbes.totalValue)")
        #expect(failedPingProbes.totalValue > 1)  // definitely at least one, we detected the down peer

        let successfulPingRequestProbes = try! self.testMetrics.expectCounter(
            firstHandler.shell.swim.metrics.successfulPingRequestProbes
        )
        print("  successfulPingRequestProbes = \(successfulPingRequestProbes.totalValue)")
        #expect(successfulPingRequestProbes.totalValue > 1)  // definitely at least one, the second peer is alive and .nacks us, so we count that as success

        let failedPingRequestProbes = try! self.testMetrics.expectCounter(
            firstHandler.shell.swim.metrics.failedPingRequestProbes
        )
        print("  failedPingRequestProbes = \(failedPingRequestProbes.totalValue)")
        #expect(failedPingRequestProbes.totalValue == 0)  // 0 because the second peer is still responsive to us, even it third is dead
    }
}
