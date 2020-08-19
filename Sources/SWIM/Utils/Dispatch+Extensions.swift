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

import enum Dispatch.DispatchTimeInterval

extension DispatchTimeInterval {
    /// Total amount of nanoseconds represented by this interval.
    ///
    /// We need this to compare amounts, yet we don't want to make to Comparable publicly.
    var nanoseconds: Int64 {
        switch self {
        case .nanoseconds(let ns): return Int64(ns)
        case .microseconds(let us): return Int64(us) * 1000
        case .milliseconds(let ms): return Int64(ms) * 1_000_000
        case .seconds(let s): return Int64(s) * 1_000_000_000
        default: return .max
        }
    }
}
