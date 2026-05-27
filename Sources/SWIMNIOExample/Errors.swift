//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Cluster Membership open source project
//
// Copyright (c) 2026 Apple Inc. and the Swift Cluster Membership project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of Swift Cluster Membership project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIO

public struct SWIMNIOTimeoutError: Error, CustomStringConvertible {
    let timeout: Duration
    let message: String

    init(timeout: NIO.TimeAmount, message: String) {
        self.timeout = .nanoseconds(Int(timeout.nanoseconds))
        self.message = message
    }

    init(timeout: Duration, message: String) {
        self.timeout = timeout
        self.message = message
    }

    public var description: String {
        "SWIMNIOTimeoutError(timeout: \(self.timeout.prettyDescription), \(self.message))"
    }
}

public struct SWIMNIOIllegalMessageTypeError: Error, CustomStringConvertible {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    public var description: String {
        "SWIMNIOIllegalMessageTypeError(\(self.message))"
    }
}
