//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Cluster Membership open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift Cluster Membership project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Cluster Membership project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import struct Dispatch.DispatchTime
import enum Dispatch.DispatchTimeInterval
import Metrics

extension Timer {
    /// Records time interval between the passed in `since` dispatch time and `now`.
    func recordInterval(since: DispatchTime, now: DispatchTime = .now()) {
        self.recordNanoseconds(now.uptimeNanoseconds - since.uptimeNanoseconds)
    }
}
