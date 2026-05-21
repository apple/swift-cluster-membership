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
import MetricsTestKit
import SWIMTestKit
import Synchronization
import Testing

@testable import CoreMetrics
@testable import SWIM

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

@Suite(.serialized)
final class SWIMMetricsTests {
    let myselfNode = ClusterMembership.Node(protocol: "test", host: "127.0.0.1", port: 7001, uid: 1111)
    let secondNode = ClusterMembership.Node(protocol: "test", host: "127.0.0.1", port: 7002, uid: 2222)
    let thirdNode = ClusterMembership.Node(protocol: "test", host: "127.0.0.1", port: 7003, uid: 3333)
    let fourthNode = ClusterMembership.Node(protocol: "test", host: "127.0.0.1", port: 7004, uid: 4444)
    let fifthNode = ClusterMembership.Node(protocol: "test", host: "127.0.0.1", port: 7005, uid: 5555)

    var myself: TestPeer!
    var second: TestPeer!
    var third: TestPeer!
    var fourth: TestPeer!
    var fifth: TestPeer!

    let metricsLabelPrefix = "swim-tests-\(UUID().uuidString)"

    init() {
        self.myself = TestPeer(node: self.myselfNode)
        self.second = TestPeer(node: self.secondNode)
        self.third = TestPeer(node: self.thirdNode)
        self.fourth = TestPeer(node: self.fourthNode)
        self.fifth = TestPeer(node: self.fifthNode)
    }

    deinit {
        self.myself = nil
        self.second = nil
        self.third = nil
        self.fourth = nil
        self.fifth = nil
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Metrics tests

    let alive = [("status", "alive")]
    let unreachable = [("status", "unreachable")]
    let dead = [("status", "dead")]

    @Test
    func test_members_becoming_suspect() throws {
        var settings = SWIM.Settings()
        settings.metrics.labelPrefix = self.metricsLabelPrefix
        settings.unreachability = .enabled

        let testMetrics: TestMetrics = TestMetrics()
        var swim = withMetricsFactory(testMetrics) {
            SWIM.Instance<TestPeer, TestPeer, TestPeer>(settings: settings, myself: self.myself)
        }
        try self.expectMembership(swim, testMetrics: testMetrics, alive: 1, unreachable: 0, totalDead: 0)

        _ = swim.addMember(self.second, status: .alive(incarnation: 0))
        try self.expectMembership(swim, testMetrics: testMetrics, alive: 2, unreachable: 0, totalDead: 0)

        _ = swim.addMember(self.third, status: .alive(incarnation: 0))
        try self.expectMembership(swim, testMetrics: testMetrics, alive: 3, unreachable: 0, totalDead: 0)

        _ = swim.addMember(self.fourth, status: .alive(incarnation: 0))
        _ = swim.onPeriodicPingTick()
        try self.expectMembership(swim, testMetrics: testMetrics, alive: 4, unreachable: 0, totalDead: 0)

        for _ in 0..<10 {
            _ = swim.onPingResponse(
                response: .timeout(
                    target: self.second,
                    pingRequestOrigin: nil,
                    timeout: .seconds(1),
                    sequenceNumber: 0
                ),
                pingRequestOrigin: nil,
                pingRequestSequenceNumber: nil
            )
            _ = swim.onPingRequestResponse(.nack(target: self.third, sequenceNumber: 0), pinged: self.second)
        }
        try expectMembership(swim, testMetrics: testMetrics, suspect: 1)

        for _ in 0..<10 {
            _ = swim.onPingResponse(
                response: .timeout(target: self.third, pingRequestOrigin: nil, timeout: .seconds(1), sequenceNumber: 0),
                pingRequestOrigin: nil,
                pingRequestSequenceNumber: nil
            )
        }
        try expectMembership(swim, testMetrics: testMetrics, suspect: 2)
    }

    enum DowningMode {
        case unreachableFirst
        case deadImmediately
    }

    @Test
    func test_members_becoming_dead() throws {
        try self.shared_members(mode: .deadImmediately)
    }

    @Test
    func test_members_becoming_unreachable() throws {
        try self.shared_members(mode: .unreachableFirst)
    }

    func shared_members(mode: DowningMode) throws {
        var settings = SWIM.Settings()
        settings.metrics.labelPrefix = self.metricsLabelPrefix
        switch mode {
        case .unreachableFirst:
            settings.unreachability = .enabled
        case .deadImmediately:
            settings.unreachability = .disabled
        }
        let mockTime = Mutex(ContinuousClock.now)
        settings.timeSourceNow = { mockTime.withLock { $0 } }
        let testMetrics: TestMetrics = TestMetrics()
        var swim = withMetricsFactory(testMetrics) {
            SWIM.Instance<TestPeer, TestPeer, TestPeer>(settings: settings, myself: self.myself)
        }

        try self.expectMembership(swim, testMetrics: testMetrics, alive: 1, unreachable: 0, totalDead: 0)

        _ = swim.addMember(self.second, status: .alive(incarnation: 0))
        try self.expectMembership(swim, testMetrics: testMetrics, alive: 2, unreachable: 0, totalDead: 0)

        _ = swim.addMember(self.third, status: .alive(incarnation: 0))
        try self.expectMembership(swim, testMetrics: testMetrics, alive: 3, unreachable: 0, totalDead: 0)

        _ = swim.addMember(self.fourth, status: .alive(incarnation: 0))
        _ = swim.onPeriodicPingTick()
        try self.expectMembership(swim, testMetrics: testMetrics, alive: 4, unreachable: 0, totalDead: 0)

        let totalMembers = 4

        for _ in 0..<10 {
            _ = swim.onPingResponse(
                response: .timeout(
                    target: self.second,
                    pingRequestOrigin: nil,
                    timeout: .seconds(1),
                    sequenceNumber: 0
                ),
                pingRequestOrigin: nil,
                pingRequestSequenceNumber: nil
            )
            mockTime.withLock { $0 = $0.advanced(by: .seconds(120)) }
            _ = swim.onPeriodicPingTick()
        }
        let (expectedUnreachables1, expectedDeads1): (Int, Int)
        switch mode {
        case .unreachableFirst: (expectedUnreachables1, expectedDeads1) = (1, 0)
        case .deadImmediately: (expectedUnreachables1, expectedDeads1) = (0, 1)
        }
        try self.expectMembership(
            swim,
            testMetrics: testMetrics,
            alive: totalMembers - expectedDeads1 - expectedUnreachables1,
            unreachable: expectedUnreachables1,
            totalDead: expectedDeads1
        )

        for _ in 0..<10 {
            _ = swim.onPingResponse(
                response: .timeout(target: self.third, pingRequestOrigin: nil, timeout: .seconds(1), sequenceNumber: 0),
                pingRequestOrigin: nil,
                pingRequestSequenceNumber: nil
            )
            mockTime.withLock { $0 = $0.advanced(by: .seconds(120)) }
            _ = swim.onPeriodicPingTick()
        }
        let (expectedUnreachables2, expectedDeads2): (Int, Int)
        switch mode {
        case .unreachableFirst: (expectedUnreachables2, expectedDeads2) = (2, 0)
        case .deadImmediately: (expectedUnreachables2, expectedDeads2) = (0, 2)
        }
        try self.expectMembership(
            swim,
            testMetrics: testMetrics,
            alive: totalMembers - expectedDeads2 - expectedUnreachables2,
            unreachable: expectedUnreachables2,
            totalDead: expectedDeads2
        )

        if mode == .unreachableFirst {
            _ = swim.confirmDead(peer: self.second)
            try self.expectMembership(
                swim,
                testMetrics: testMetrics,
                alive: totalMembers - expectedDeads2 - expectedUnreachables2,
                unreachable: expectedUnreachables2 - 1,
                totalDead: expectedDeads2 + 1
            )

            let gotRemovedDeadTombstones = try testMetrics.expectRecorder(
                swim.metrics.removedDeadMemberTombstones
            ).lastValue!
            #expect(gotRemovedDeadTombstones == Double(expectedDeads2 + 1))
        }
    }

    @Test
    func test_lha_adjustment() throws {
        var settings = SWIM.Settings()
        settings.metrics.labelPrefix = self.metricsLabelPrefix

        let testMetrics: TestMetrics = TestMetrics()
        var swim = withMetricsFactory(testMetrics) {
            SWIM.Instance<TestPeer, TestPeer, TestPeer>(settings: settings, myself: self.myself)
        }
        _ = swim.addMember(self.second, status: .alive(incarnation: 0))
        _ = swim.addMember(self.third, status: .alive(incarnation: 0))

        try #expect(testMetrics.expectRecorder(swim.metrics.localHealthMultiplier).lastValue == Double(0))

        swim.adjustLHMultiplier(.failedProbe)
        try #expect(testMetrics.expectRecorder(swim.metrics.localHealthMultiplier).lastValue == Double(1))

        swim.adjustLHMultiplier(.failedProbe)
        try #expect(testMetrics.expectRecorder(swim.metrics.localHealthMultiplier).lastValue == Double(2))

        swim.adjustLHMultiplier(.successfulProbe)
        try #expect(testMetrics.expectRecorder(swim.metrics.localHealthMultiplier).lastValue == Double(1))
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Assertions

extension SWIMMetricsTests {
    private func expectMembership(
        _ swim: SWIM.Instance<TestPeer, TestPeer, TestPeer>,
        testMetrics: TestMetrics,
        suspect: Int,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let m: SWIM.Metrics = swim.metrics

        let gotSuspect: Double? = try testMetrics.expectRecorder(m.membersSuspect).lastValue
        #expect(
            gotSuspect == Double(suspect),
            """
            Expected \(suspect) [alive] members, was: \(String(reflecting: gotSuspect)); Members:
            \(swim.members.map(\.description).joined(separator: "\n"))
            """,
            sourceLocation: sourceLocation
        )
    }

    private func expectMembership(
        _ swim: SWIM.Instance<TestPeer, TestPeer, TestPeer>,
        testMetrics: TestMetrics,
        alive: Int,
        unreachable: Int,
        totalDead: Int,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let m: SWIM.Metrics = swim.metrics

        let gotAlive: Double? = try testMetrics.expectRecorder(m.membersAlive).lastValue
        #expect(
            gotAlive == Double(alive),
            """
            Expected \(alive) [alive] members, was: \(String(reflecting: gotAlive)); Members:
            \(swim.members.map(\.description).joined(separator: "\n"))
            """,
            sourceLocation: sourceLocation
        )

        let gotUnreachable: Double? = try testMetrics.expectRecorder(m.membersUnreachable).lastValue
        #expect(
            gotUnreachable == Double(unreachable),
            """
            Expected \(unreachable) [unreachable] members, was: \(String(reflecting: gotUnreachable)); Members:
            \(swim.members.map(\.description).joined(separator: "\n")))
            """,
            sourceLocation: sourceLocation
        )

        let gotTotalDead: Int64? = try testMetrics.expectCounter(m.membersTotalDead).totalValue
        #expect(
            gotTotalDead == Int64(totalDead),
            """
            Expected \(totalDead) [dead] members, was: \(String(reflecting: gotTotalDead)); Members:
            \(swim.members.map(\.description).joined(separator: "\n"))
            """,
            sourceLocation: sourceLocation
        )
    }
}
