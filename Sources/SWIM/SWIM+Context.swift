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
import Logging

public protocol SWIMContext {
    var node: ClusterMembership.Node { get }
    var log: Logger { get set }

    var peer: SWIMPeerProtocol { get }
    func peer(on node: Node) -> SWIMPeerProtocol

    func startTimer(key: String, delay: SWIMTimeAmount, _ task: @escaping () -> Void) -> Cancellable
}

public struct Cancellable {
    private var _cancel: () -> Void

    init(_ _cancel: @escaping () -> Void) {
        self._cancel = _cancel
    }

    func cancel() {
        self._cancel()
    }
}
