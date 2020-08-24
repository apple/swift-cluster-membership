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
import NIO
import SWIM
@testable import SWIMNIO
import XCTest

final class SWIMNIOEmbeddedTests: EmbeddedClusteredXCTestCase {
    let firstNode = Node(protocol: "test", host: "127.0.0.1", port: 7001, uid: 1111)
    let secondNode = Node(protocol: "test", host: "127.0.0.1", port: 7002, uid: 1111)

    func test_embedded_schedulingPeriodicTicksWorks() throws {
        let first = self.makeEmbeddedShell("first") { settings in
            settings.swim.initialContactPoints = [secondNode]
            settings.swim.node = firstNode
        }
        let second = self.makeEmbeddedShell("second") { settings in
            settings.swim.initialContactPoints = []
            settings.swim.node = secondNode
        }

        for _ in 0 ... 5 {
            self.loop.advanceTime(by: .seconds(1))
            self.exchangeMessages(first, second)
        }

        XCTAssertEqual(first.swim.allMemberCount, 2)
        XCTAssertEqual(second.swim.allMemberCount, 2)
    }

    private func exchangeMessages(_ first: SWIMNIOShell, _ second: SWIMNIOShell) {
        let firstEmbeddedChannel = first.channel as! EmbeddedChannel
        let secondEmbeddedChannel = second.channel as! EmbeddedChannel

        if let writeCommand = try! firstEmbeddedChannel.readOutbound(as: WriteCommand.self) {
            second.receiveMessage(message: writeCommand.message)
        }
        if let writeCommand = try! secondEmbeddedChannel.readOutbound(as: WriteCommand.self) {
            first.receiveMessage(message: writeCommand.message)
        }
    }
}
