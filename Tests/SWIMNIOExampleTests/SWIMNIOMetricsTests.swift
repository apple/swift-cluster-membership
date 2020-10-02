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
@testable import CoreMetrics
import Dispatch
import Metrics
import NIO
@testable import SWIM
@testable import SWIMNIOExample
import SWIMTestKit
import XCTest

final class SWIMNIOMetricsTests: RealClusteredXCTestCase {
    var testMetrics: TestMetrics!

    override func setUp() {
        super.setUp()

        self.testMetrics = TestMetrics()
        MetricsSystem.bootstrapInternal(self.testMetrics)
    }

    override func tearDown() {
        super.tearDown()
        MetricsSystem.bootstrapInternal(NOOPMetricsHandler.instance)
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Metrics tests

    func test_metrics_emittedByNIOImplementation() throws {
        let (firstHandler, _) = self.makeClusterNode() { settings in
            settings.swim.metrics.labelPrefix = "first"
            settings.swim.probeInterval = .milliseconds(100)
        }
        _ = self.makeClusterNode() { settings in
            settings.swim.metrics.labelPrefix = "second"
            settings.swim.probeInterval = .milliseconds(100)
            settings.swim.initialContactPoints = [firstHandler.shell.node]
        }
        let (_, thirdChannel) = self.makeClusterNode() { settings in
            settings.swim.metrics.labelPrefix = "third"
            settings.swim.probeInterval = .milliseconds(100)
            settings.swim.initialContactPoints = [firstHandler.shell.node]
        }

        sleep(1) // giving it some extra time to report a few metrics (a few round-trip times etc).

        let m: SWIM.Metrics.ShellMetrics = firstHandler.metrics!

        let roundTripTime = try! self.testMetrics.expectTimer(m.pingResponseTime)
        XCTAssertNotNil(roundTripTime.lastValue) // some roundtrip time should have been reported
        for rtt in roundTripTime.values {
            print("  ping rtt recorded: \(TimeAmount.nanoseconds(rtt).prettyDescription)")
        }

        let messageInboundCount = try! self.testMetrics.expectCounter(m.messageInboundCount)
        let messageInboundBytes = try! self.testMetrics.expectRecorder(m.messageInboundBytes)
        print("  messageInboundCount = \(messageInboundCount.totalValue)")
        print("  messageInboundBytes = \(messageInboundBytes.lastValue!)")
        XCTAssertGreaterThan(messageInboundCount.totalValue, 0)
        XCTAssertGreaterThan(messageInboundBytes.lastValue!, 0)

        let messageOutboundCount = try! self.testMetrics.expectCounter(m.messageOutboundCount)
        let messageOutboundBytes = try! self.testMetrics.expectRecorder(m.messageOutboundBytes)
        print("  messageOutboundCount = \(messageOutboundCount.totalValue)")
        print("  messageOutboundBytes = \(messageOutboundBytes.lastValue!)")
        XCTAssertGreaterThan(messageOutboundCount.totalValue, 0)
        XCTAssertGreaterThan(messageOutboundBytes.lastValue!, 0)

        thirdChannel.close(promise: nil)
        sleep(2)

        let pingRequestResponseTimeAll = try! self.testMetrics.expectTimer(m.pingRequestResponseTimeAll)
        print("  pingRequestResponseTimeAll = \(pingRequestResponseTimeAll.lastValue!)")
        XCTAssertGreaterThan(pingRequestResponseTimeAll.lastValue!, 0)

        let pingRequestResponseTimeFirst = try! self.testMetrics.expectTimer(m.pingRequestResponseTimeFirst)
        XCTAssertNil(pingRequestResponseTimeFirst.lastValue) // because this only counts ACKs, and we get NACKs because the peer is down

        let successfulPingProbes = try! self.testMetrics.expectCounter(firstHandler.shell.swim.metrics.successfulPingProbes)
        print("  successfulPingProbes = \(successfulPingProbes.totalValue)")
        XCTAssertGreaterThan(successfulPingProbes.totalValue, 1) // definitely at least one, we joined some nodes

        let failedPingProbes = try! self.testMetrics.expectCounter(firstHandler.shell.swim.metrics.failedPingProbes)
        print("  failedPingProbes = \(failedPingProbes.totalValue)")
        XCTAssertGreaterThan(failedPingProbes.totalValue, 1) // definitely at least one, we detected the down peer

        let successfulPingRequestProbes = try! self.testMetrics.expectCounter(firstHandler.shell.swim.metrics.successfulPingRequestProbes)
        print("  successfulPingRequestProbes = \(successfulPingRequestProbes.totalValue)")
        XCTAssertGreaterThan(successfulPingRequestProbes.totalValue, 1) // definitely at least one, the second peer is alive and .nacks us, so we count that as success

        let failedPingRequestProbes = try! self.testMetrics.expectCounter(firstHandler.shell.swim.metrics.failedPingRequestProbes)
        print("  failedPingRequestProbes = \(failedPingRequestProbes.totalValue)")
        XCTAssertEqual(failedPingRequestProbes.totalValue, 0) // 0 because the second peer is still responsive to us, even it third is dead
    }
}
