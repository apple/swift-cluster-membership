//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Cluster Membership open source project
//
// Copyright (c) 2018-2019 Apple Inc. and the Swift Cluster Membership project authors
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
import Metrics
@testable import SWIM
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

    enum DowningMode {
        case unreachable
        case dead
    }

    func test_members_becoming_dead() {
        self.shared_members(mode: .dead)
    }

    func test_members_becoming_dead() {
        self.shared_members(mode: .dead)
    }

    func shared_members(mode: DowningMode) {
        let swim = SWIM.Instance(settings: .init(), myself: self.myself)

        self.expectMembership(swim, alive: 1, unreachable: 0, dead: 0)

        _ = swim.addMember(self.second, status: .alive(incarnation: 0))
        self.expectMembership(swim, alive: 2, unreachable: 0, dead: 0)

        _ = swim.addMember(self.third, status: .alive(incarnation: 0))
        self.expectMembership(swim, alive: 3, unreachable: 0, dead: 0)

        _ = swim.addMember(self.fourth, status: .alive(incarnation: 0))
        _ = swim.onPeriodicPingTick()
        self.expectMembership(swim, alive: 4, unreachable: 0, dead: 0)

        for _ in 0 ..< 10 {
            _ = swim.onPingResponse(
                response: .timeout(target: second, pingRequestOrigin: nil, timeout: .seconds(1), sequenceNumber: 0),
                pingRequestOrigin: nil,
                pingRequestSequenceNumber: nil
            )
        }
        self.expectMembership(swim, alive: 3, unreachable: 0, dead: 1)

        for _ in 0 ..< 10 {
            _ = swim.onPingResponse(
                response: .timeout(target: second, pingRequestOrigin: nil, timeout: .seconds(1), sequenceNumber: 0),
                pingRequestOrigin: nil,
                pingRequestSequenceNumber: nil
            )
        }
        self.expectMembership(swim, alive: 3, unreachable: 0, dead: 2)
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Assertions

extension SWIMMetricsTests {
    private func expectMembership(_ swim: SWIM.Instance, alive: Double, unreachable: Double, dead: Double, file: StaticString = #file, line: UInt = #line) {
        let m: SWIM.Metrics = swim.metrics
        try XCTAssertEqual(self.testMetrics.expectRecorder(m.membersAlive).lastValue, alive, file: file, line: line)
        try XCTAssertEqual(self.testMetrics.expectRecorder(m.membersUnreachable).lastValue, unreachable, file: file, line: line)
        try XCTAssertEqual(self.testMetrics.expectRecorder(m.membersDead).lastValue, dead, file: file, line: line)
    }
}
