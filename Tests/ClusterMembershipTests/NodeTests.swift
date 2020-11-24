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

@testable import ClusterMembership
import XCTest

final class NodeTests: XCTestCase {
    let firstNode = ClusterMembership.Node(protocol: "test", host: "127.0.0.1", port: 7001, uid: 1111)
    let secondNode = ClusterMembership.Node(protocol: "test", host: "127.0.0.1", port: 7002, uid: 2222)
    let thirdNode = ClusterMembership.Node(protocol: "test", host: "127.0.0.2", port: 7001, uid: 3333)

    func testCompareSameProtocolAndHost() throws {
        XCTAssertLessThan(self.firstNode, self.secondNode)
        XCTAssertGreaterThan(self.secondNode, self.firstNode)
        XCTAssertNotEqual(self.firstNode, self.secondNode)
    }

    func testCompareDifferentHost() throws {
        XCTAssertLessThan(self.firstNode, self.thirdNode)
        XCTAssertGreaterThan(self.thirdNode, self.firstNode)
        XCTAssertNotEqual(self.firstNode, self.thirdNode)
        XCTAssertLessThan(self.secondNode, self.thirdNode)
        XCTAssertGreaterThan(self.thirdNode, self.secondNode)
    }

    func testSort() throws {
        let nodes: Set<ClusterMembership.Node> = [secondNode, firstNode, thirdNode]
        let sorted_nodes = nodes.sorted()

        XCTAssertEqual(sorted_nodes, [self.firstNode, self.secondNode, self.thirdNode])
    }
}
