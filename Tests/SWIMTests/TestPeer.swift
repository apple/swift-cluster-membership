//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Cluster Membership open source project
//
// Copyright (c) 2018-2022 Apple Inc. and the Swift Cluster Membership project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of Swift Cluster Membership project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import ClusterMembership
import Foundation

@testable import SWIM

final class TestPeer: Hashable, CustomStringConvertible, Sendable {
    let swimNode: Node

    init(node: Node) {
        self.swimNode = node
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(self.swimNode)
    }

    static func == (lhs: TestPeer, rhs: TestPeer) -> Bool {
        lhs.swimNode == rhs.swimNode
    }

    var description: String {
        "TestPeer(\(self.swimNode))"
    }
}
