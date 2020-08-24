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
@testable import SWIM
import XCTest

final class SWIMSettingsTests: XCTestCase {
    func test_gossipedEnoughTimes() {
        let settings = SWIM.Settings()

        let node = ClusterMembership.Node(protocol: "test", host: "127.0.0.1", port: 7001, uid: 1111)
        let member = SWIM.Member(peer: TestPeer(node: node), status: .alive(incarnation: 0), protocolPeriod: 0)
        var g = SWIM.Gossip(member: member, numberOfTimesGossiped: 0)

        var members = 0

        // just 1 member, means no other peers thus we dont have to gossip ever
        members = 1
        g.numberOfTimesGossiped = 0
        XCTAssertEqual(settings.gossip.gossipedEnoughTimes(g, members: members), false)
        g.numberOfTimesGossiped = 1
        XCTAssertEqual(settings.gossip.gossipedEnoughTimes(g, members: members), false)

        members = 2
        g.numberOfTimesGossiped = 0
        for _ in 0 ... 3 {
            XCTAssertEqual(settings.gossip.gossipedEnoughTimes(g, members: members), false)
            g.numberOfTimesGossiped += 1
        }

        members = 10
        g.numberOfTimesGossiped = 0
        for _ in 0 ... 9 {
            XCTAssertEqual(settings.gossip.gossipedEnoughTimes(g, members: members), false)
            g.numberOfTimesGossiped += 1
        }

        members = 50
        g.numberOfTimesGossiped = 0
        for _ in 0 ... 16 {
            XCTAssertEqual(settings.gossip.gossipedEnoughTimes(g, members: members), false)
            g.numberOfTimesGossiped += 1
        }

        members = 200
        g.numberOfTimesGossiped = 0
        for _ in 0 ... 21 {
            XCTAssertEqual(settings.gossip.gossipedEnoughTimes(g, members: members), false)
            g.numberOfTimesGossiped += 1
        }
    }
}
