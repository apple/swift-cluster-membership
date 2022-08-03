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

import NIO
import SWIM

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

    var toNIO: NIO.TimeAmount {
        .nanoseconds(self.nanoseconds)
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

protocol PrettyTimeAmountDescription {
    var nanoseconds: Int64 { get }
    var isEffectivelyInfinite: Bool { get }

    var prettyDescription: String { get }
    func prettyDescription(precision: Int) -> String
}

extension PrettyTimeAmountDescription {
    var prettyDescription: String {
        self.prettyDescription()
    }

    func prettyDescription(precision: Int = 2) -> String {
        assert(precision > 0, "precision MUST BE > 0")
        if self.isEffectivelyInfinite {
            return "∞ (infinite)"
        }

        var res = ""
        var remainingNanos = self.nanoseconds

        if remainingNanos < 0 {
            res += "-"
            remainingNanos = remainingNanos * -1
        }

        var i = 0
        while i < precision {
            let unit = self.chooseUnit(remainingNanos)

            let rounded = Int(remainingNanos / unit.rawValue)
            if rounded > 0 {
                res += i > 0 ? " " : ""
                res += "\(rounded)\(unit.abbreviated)"

                remainingNanos = remainingNanos - unit.timeAmount(rounded).nanoseconds
                i += 1
            } else {
                break
            }
        }

        return res
    }

    private func chooseUnit(_ ns: Int64) -> PrettyTimeUnit {
        if ns / PrettyTimeUnit.days.rawValue > 0 {
            return PrettyTimeUnit.days
        } else if ns / PrettyTimeUnit.hours.rawValue > 0 {
            return PrettyTimeUnit.hours
        } else if ns / PrettyTimeUnit.minutes.rawValue > 0 {
            return PrettyTimeUnit.minutes
        } else if ns / PrettyTimeUnit.seconds.rawValue > 0 {
            return PrettyTimeUnit.seconds
        } else if ns / PrettyTimeUnit.milliseconds.rawValue > 0 {
            return PrettyTimeUnit.milliseconds
        } else if ns / PrettyTimeUnit.microseconds.rawValue > 0 {
            return PrettyTimeUnit.microseconds
        } else {
            return PrettyTimeUnit.nanoseconds
        }
    }
}

/// Represents number of nanoseconds within given time unit
enum PrettyTimeUnit: Int64 {
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

    func timeAmount(_ amount: Int) -> TimeAmount {
        switch self {
        case .nanoseconds: return .nanoseconds(Int64(amount))
        case .microseconds: return .microseconds(Int64(amount))
        case .milliseconds: return .milliseconds(Int64(amount))
        case .seconds: return .seconds(Int64(amount))
        case .minutes: return .minutes(Int64(amount))
        case .hours: return .hours(Int64(amount))
        case .days: return .hours(Int64(amount) * 24)
        }
    }
}

extension NIO.TimeAmount: PrettyTimeAmountDescription {
    var isEffectivelyInfinite: Bool {
        self.nanoseconds == .max
    }
}

extension Swift.Duration: PrettyTimeAmountDescription {}
