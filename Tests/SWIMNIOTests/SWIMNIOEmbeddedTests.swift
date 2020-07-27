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
import NIO

final class SWIMNIOEmbeddedTests: ClusteredXCTestCase {
    override var alwaysPrintCaptureLogs: Bool {
        true
    }

    func test_embedded_peers_2_connect() throws {
        let first = self.makeShell(name: "first")
        let second = self.makeShell(name: "second")

        let firstPeer = first.peer as! SWIM.NIOPeer
        let secondPeer = second.peer as! SWIM.NIOPeer

        first.receiveMessage(message: .ping(replyTo: secondPeer, payload: .none, sequenceNr: 1))
        self.loop.advanceTime(by: .seconds(1))

        try self.capturedLogs(of: first.node).shouldContain(grep: "Checking suspicion timeouts")
    }
}
