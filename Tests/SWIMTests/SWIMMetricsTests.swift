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
@testable import SWIM
import SWIMTestKit
import XCTest

final class SWIMMetricsTests: XCTestCase {
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

    var testMetrics: TestMetrics!

    override func setUp() {
        super.setUp()
        self.myself = TestPeer(node: self.myselfNode)
        self.second = TestPeer(node: self.secondNode)
        self.third = TestPeer(node: self.thirdNode)
        self.fourth = TestPeer(node: self.fourthNode)
        self.fifth = TestPeer(node: self.fifthNode)

        self.testMetrics = TestMetrics()
        MetricsSystem.bootstrapInternal(self.testMetrics)
    }

    override func tearDown() {
        super.tearDown()
        self.myself = nil
        self.second = nil
        self.third = nil
        self.fourth = nil
        self.fifth = nil

        MetricsSystem.bootstrapInternal(NOOPMetricsHandler.instance)
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Metrics tests

    let alive = [("status", "alive")]
    let unreachable = [("status", "unreachable")]
    let dead = [("status", "dead")]

    func test_members_becoming_suspect() {
        var settings = SWIM.Settings()
        settings.unreachability = .enabled
        var swim = SWIM.Instance<TestPeer, TestPeer, TestPeer>(settings: settings, myself: self.myself)

        self.expectMembership(swim, alive: 1, unreachable: 0, totalDead: 0)

        _ = swim.addMember(self.second, status: .alive(incarnation: 0))
        self.expectMembership(swim, alive: 2, unreachable: 0, totalDead: 0)

        _ = swim.addMember(self.third, status: .alive(incarnation: 0))
        self.expectMembership(swim, alive: 3, unreachable: 0, totalDead: 0)

        _ = swim.addMember(self.fourth, status: .alive(incarnation: 0))
        _ = swim.onPeriodicPingTick()
        self.expectMembership(swim, alive: 4, unreachable: 0, totalDead: 0)

        for _ in 0 ..< 10 {
            _ = swim.onPingResponse(
                response: .timeout(target: self.second, pingRequestOrigin: nil, timeout: .seconds(1), sequenceNumber: 0),
                pingRequestOrigin: nil,
                pingRequestSequenceNumber: nil
            )
            _ = swim.onPingRequestResponse(.nack(target: self.third, sequenceNumber: 0), pinged: self.second)
        }
        expectMembership(swim, suspect: 1)

        for _ in 0 ..< 10 {
            _ = swim.onPingResponse(
                response: .timeout(target: self.third, pingRequestOrigin: nil, timeout: .seconds(1), sequenceNumber: 0),
                pingRequestOrigin: nil,
                pingRequestSequenceNumber: nil
            )
        }
        expectMembership(swim, suspect: 2)
    }

    enum DowningMode {
        case unreachableFirst
        case deadImmediately
    }

    func test_members_becoming_dead() {
        self.shared_members(mode: .deadImmediately)
    }

    func test_members_becoming_unreachable() {
        self.shared_members(mode: .unreachableFirst)
    }

    func shared_members(mode: DowningMode) {
        var settings = SWIM.Settings()
        switch mode {
        case .unreachableFirst:
            settings.unreachability = .enabled
        case .deadImmediately:
            settings.unreachability = .disabled
        }
        var mockTime = DispatchTime.now()
        settings.timeSourceNow = { mockTime }
        var swim = SWIM.Instance<TestPeer, TestPeer, TestPeer>(settings: settings, myself: self.myself)

        self.expectMembership(swim, alive: 1, unreachable: 0, totalDead: 0)

        _ = swim.addMember(self.second, status: .alive(incarnation: 0))
        self.expectMembership(swim, alive: 2, unreachable: 0, totalDead: 0)

        _ = swim.addMember(self.third, status: .alive(incarnation: 0))
        self.expectMembership(swim, alive: 3, unreachable: 0, totalDead: 0)

        _ = swim.addMember(self.fourth, status: .alive(incarnation: 0))
        _ = swim.onPeriodicPingTick()
        self.expectMembership(swim, alive: 4, unreachable: 0, totalDead: 0)

        let totalMembers = 4

        for _ in 0 ..< 10 {
            _ = swim.onPingResponse(
                response: .timeout(target: self.second, pingRequestOrigin: nil, timeout: .seconds(1), sequenceNumber: 0),
                pingRequestOrigin: nil,
                pingRequestSequenceNumber: nil
            )
            mockTime = mockTime + DispatchTimeInterval.seconds(120)
            _ = swim.onPeriodicPingTick()
        }
        let (expectedUnreachables1, expectedDeads1): (Int, Int)
        switch mode {
        case .unreachableFirst: (expectedUnreachables1, expectedDeads1) = (1, 0)
        case .deadImmediately: (expectedUnreachables1, expectedDeads1) = (0, 1)
        }
        self.expectMembership(swim, alive: totalMembers - expectedDeads1 - expectedUnreachables1, unreachable: expectedUnreachables1, totalDead: expectedDeads1)

        for _ in 0 ..< 10 {
            _ = swim.onPingResponse(
                response: .timeout(target: self.third, pingRequestOrigin: nil, timeout: .seconds(1), sequenceNumber: 0),
                pingRequestOrigin: nil,
                pingRequestSequenceNumber: nil
            )
            mockTime = mockTime + DispatchTimeInterval.seconds(120)
            _ = swim.onPeriodicPingTick()
        }
        let (expectedUnreachables2, expectedDeads2): (Int, Int)
        switch mode {
        case .unreachableFirst: (expectedUnreachables2, expectedDeads2) = (2, 0)
        case .deadImmediately: (expectedUnreachables2, expectedDeads2) = (0, 2)
        }
        self.expectMembership(swim, alive: totalMembers - expectedDeads2 - expectedUnreachables2, unreachable: expectedUnreachables2, totalDead: expectedDeads2)

        if mode == .unreachableFirst {
            _ = swim.confirmDead(peer: self.second)
            self.expectMembership(swim, alive: totalMembers - expectedDeads2 - expectedUnreachables2, unreachable: expectedUnreachables2 - 1, totalDead: expectedDeads2 + 1)

            let gotRemovedDeadTombstones = try! self.testMetrics.expectRecorder(swim.metrics.removedDeadMemberTombstones).lastValue!
            XCTAssertEqual(gotRemovedDeadTombstones, Double(expectedDeads2 + 1))
        }
    }

    func test_lha_adjustment() {
        let settings = SWIM.Settings()
        var swim = SWIM.Instance<TestPeer, TestPeer, TestPeer>(settings: settings, myself: self.myself)

        _ = swim.addMember(self.second, status: .alive(incarnation: 0))
        _ = swim.addMember(self.third, status: .alive(incarnation: 0))

        XCTAssertEqual(try! self.testMetrics.expectRecorder(swim.metrics.localHealthMultiplier).lastValue, Double(0))

        swim.adjustLHMultiplier(.failedProbe)
        XCTAssertEqual(try! self.testMetrics.expectRecorder(swim.metrics.localHealthMultiplier).lastValue, Double(1))

        swim.adjustLHMultiplier(.failedProbe)
        XCTAssertEqual(try! self.testMetrics.expectRecorder(swim.metrics.localHealthMultiplier).lastValue, Double(2))

        swim.adjustLHMultiplier(.successfulProbe)
        XCTAssertEqual(try! self.testMetrics.expectRecorder(swim.metrics.localHealthMultiplier).lastValue, Double(1))
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Assertions

extension SWIMMetricsTests {
    private func expectMembership(_ swim: SWIM.Instance<TestPeer, TestPeer, TestPeer>, suspect: Int, file: StaticString = #file, line: UInt = #line) {
        let m: SWIM.Metrics = swim.metrics

        let gotSuspect: Double? = try! self.testMetrics.expectRecorder(m.membersSuspect).lastValue
        XCTAssertEqual(
            gotSuspect,
            Double(suspect),
            """
            Expected \(suspect) [alive] members, was: \(String(reflecting: gotSuspect)); Members:
            \(swim.members.map(\.description).joined(separator: "\n"))
            """,
            file: file,
            line: line
        )
    }

    private func expectMembership(_ swim: SWIM.Instance<TestPeer, TestPeer, TestPeer>, alive: Int, unreachable: Int, totalDead: Int, file: StaticString = #file, line: UInt = #line) {
        let m: SWIM.Metrics = swim.metrics

        let gotAlive: Double? = try! self.testMetrics.expectRecorder(m.membersAlive).lastValue
        XCTAssertEqual(
            gotAlive,
            Double(alive),
            """
            Expected \(alive) [alive] members, was: \(String(reflecting: gotAlive)); Members:
            \(swim.members.map(\.description).joined(separator: "\n"))
            """,
            file: file,
            line: line
        )

        let gotUnreachable: Double? = try! self.testMetrics.expectRecorder(m.membersUnreachable).lastValue
        XCTAssertEqual(
            gotUnreachable,
            Double(unreachable),
            """
            Expected \(unreachable) [unreachable] members, was: \(String(reflecting: gotUnreachable)); Members:
            \(swim.members.map(\.description).joined(separator: "\n")))
            """,
            file: file,
            line: line
        )

        let gotTotalDead: Int64? = try! self.testMetrics.expectCounter(m.membersTotalDead).totalValue
        XCTAssertEqual(
            gotTotalDead,
            Int64(totalDead),
            """
            Expected \(totalDead) [dead] members, was: \(String(reflecting: gotTotalDead)); Members:
            \(swim.members.map(\.description).joined(separator: "\n"))
            """,
            file: file,
            line: line
        )
    }
}
