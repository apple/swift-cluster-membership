//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Cluster Membership open source project
//
// Copyright (c) 2018-2019 Apple Inc. and the Swift Cluster Membership project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of Swift Cluster Membership project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Testing

@testable import ClusterMembership

struct NodeTests {
    let firstNode = ClusterMembership.Node(protocol: "test", host: "127.0.0.1", port: 7001, uid: 1111)
    let secondNode = ClusterMembership.Node(protocol: "test", host: "127.0.0.1", port: 7002, uid: 2222)
    let thirdNode = ClusterMembership.Node(protocol: "test", host: "127.0.0.2", port: 7001, uid: 3333)

    @Test
    func testCompareSameProtocolAndHost() throws {
        #expect(self.firstNode < self.secondNode)
        #expect(self.secondNode > self.firstNode)
        #expect(self.firstNode != self.secondNode)
    }

    @Test
    func testCompareDifferentHost() throws {
        #expect(self.firstNode < self.thirdNode)
        #expect(self.thirdNode > self.firstNode)
        #expect(self.firstNode != self.thirdNode)
        #expect(self.secondNode < self.thirdNode)
        #expect(self.thirdNode > self.secondNode)
    }

    @Test
    func testSort() throws {
        let nodes: Set<ClusterMembership.Node> = [secondNode, firstNode, thirdNode]
        let sorted_nodes = nodes.sorted()

        #expect(sorted_nodes == [self.firstNode, self.secondNode, self.thirdNode])
    }
}
