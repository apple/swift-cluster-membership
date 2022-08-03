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

extension Swift.Duration {
    typealias Value = Int64

    var nanoseconds: Value {
        let (seconds, attoseconds) = self.components
        let sNanos = seconds * Value(1_000_000_000)
        let asNanos = attoseconds / Value(1_000_000_000)
        let (totalNanos, overflow) = sNanos.addingReportingOverflow(asNanos)
        return overflow ? .max : totalNanos
    }

    /// The microseconds representation of the `TimeAmount`.
    var microseconds: Value {
        self.nanoseconds / TimeUnit.microseconds.rawValue
    }

    /// The milliseconds representation of the `TimeAmount`.
    var milliseconds: Value {
        self.nanoseconds / TimeUnit.milliseconds.rawValue
    }

    /// The seconds representation of the `TimeAmount`.
    var seconds: Value {
        self.nanoseconds / TimeUnit.seconds.rawValue
    }

    var isEffectivelyInfinite: Bool {
        self.nanoseconds == .max
    }

    /// Represents number of nanoseconds within given time unit
    enum TimeUnit: Value {
        case days = 86_400_000_000_000
        case hours = 3_600_000_000_000
        case minutes = 60_000_000_000
        case seconds = 1_000_000_000
        case milliseconds = 1_000_000
        case microseconds = 1000
        case nanoseconds = 1

        var abbreviated: String {
            switch self {
            case .nanoseconds: return "ns"
            case .microseconds: return "μs"
            case .milliseconds: return "ms"
            case .seconds: return "s"
            case .minutes: return "m"
            case .hours: return "h"
            case .days: return "d"
            }
        }

        func duration(_ duration: Int) -> Duration {
            switch self {
            case .nanoseconds: return .nanoseconds(Value(duration))
            case .microseconds: return .microseconds(Value(duration))
            case .milliseconds: return .milliseconds(Value(duration))
            case .seconds: return .seconds(Value(duration))
            case .minutes: return .seconds(Value(duration) * 60)
            case .hours: return .seconds(Value(duration) * 60 * 60)
            case .days: return .seconds(Value(duration) * 24 * 60 * 60)
            }
        }
    }
}
