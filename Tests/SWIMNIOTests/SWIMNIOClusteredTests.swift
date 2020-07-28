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
import Logging

final class SWIMNIOClusteredTests: RealClusteredXCTestCase {

    override var alwaysPrintCaptureLogs: Bool {
        true
    }

    func test_real_peers_2_connect() throws {
        let (firstHandler, firstChannel) = self.makeClusterNode(name: "first")
        
        let (secondHandler, secondChannel) = self.makeClusterNode(name: "second") { settings in
            settings.initialContactPoints = [firstHandler.shell.node]
        }

        sleep(3)

        print("firstHandler.shell.swim.allMembers == \(firstHandler.shell.swim.allMembers)")
        print("secondHandler.shell.swim.allMembers == \(secondHandler.shell.swim.allMembers)")
    }
}
