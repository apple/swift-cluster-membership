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
import SWIM
@testable import SWIMNIO
import XCTest

final class SWIMNIOEmbeddedTests: XCTestCase {
    lazy var nioPeer = SWIM.NIOPeer(node: .init(protocol: "udp", host: "localhost", port: 1111, uid: 12121), channel: nil)
    lazy var nioPeerOther = SWIM.NIOPeer(node: .init(protocol: "udp", host: "127.0.0.1", port: 2222, uid: 234_324), channel: nil)

    lazy var memberOne: SWIM.Member = .init(peer: nioPeer, status: .alive(incarnation: 1), protocolPeriod: 0)
    lazy var memberTwo: SWIM.Member = .init(peer: nioPeer, status: .alive(incarnation: 2), protocolPeriod: 0)
    lazy var memberThree: SWIM.Member = .init(peer: nioPeer, status: .alive(incarnation: 2), protocolPeriod: 0)

    func test_embedded_peers_2_connect() throws {
        () // ok
    }
}
