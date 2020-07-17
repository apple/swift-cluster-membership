//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Cluster Membership open source project
//
// Copyright (c) 2018-2020 Apple Inc. and the Swift Cluster Membership project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Cluster Membership project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import struct Dispatch.DispatchTime

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: TimeAmount

/// Represents a time _interval_.
///
/// Equivalent to `NIO.TimeAmount`.
///
/// - note: `TimeAmount` should not be used to represent a point in time.
public struct SWIMTimeAmount: Codable {
    public typealias Value = Int64

    /// The nanoseconds representation of the `TimeAmount`.
    public let nanoseconds: Value

    fileprivate init(_ nanoseconds: Value) {
        self.nanoseconds = nanoseconds
    }

    /// Creates a new `TimeAmount` for the given amount of nanoseconds.
    ///
    /// - parameters:
    ///     - amount: the amount of nanoseconds this `TimeAmount` represents.
    /// - returns: the `TimeAmount` for the given amount.
    public static func nanoseconds(_ amount: Value) -> SWIMTimeAmount {
        SWIMTimeAmount(amount)
    }

    public static func nanoseconds(_ amount: Int) -> SWIMTimeAmount {
        self.nanoseconds(Value(amount))
    }

    /// Creates a new `TimeAmount` for the given amount of microseconds.
    ///
    /// - parameters:
    ///     - amount: the amount of microseconds this `TimeAmount` represents.
    /// - returns: the `TimeAmount` for the given amount.
    public static func microseconds(_ amount: Value) -> SWIMTimeAmount {
        SWIMTimeAmount(amount * 1000)
    }

    public static func microseconds(_ amount: Int) -> SWIMTimeAmount {
        self.microseconds(Value(amount))
    }

    /// Creates a new `TimeAmount` for the given amount of milliseconds.
    ///
    /// - parameters:
    ///     - amount: the amount of milliseconds this `TimeAmount` represents.
    /// - returns: the `TimeAmount` for the given amount.
    public static func milliseconds(_ amount: Value) -> SWIMTimeAmount {
        SWIMTimeAmount(amount * 1000 * 1000)
    }

    public static func milliseconds(_ amount: Int) -> SWIMTimeAmount {
        self.milliseconds(Value(amount))
    }

    /// Creates a new `TimeAmount` for the given amount of seconds.
    ///
    /// - parameters:
    ///     - amount: the amount of seconds this `TimeAmount` represents.
    /// - returns: the `TimeAmount` for the given amount.
    public static func seconds(_ amount: Value) -> SWIMTimeAmount {
        SWIMTimeAmount(amount * 1000 * 1000 * 1000)
    }

    public static func seconds(_ amount: Int) -> SWIMTimeAmount {
        self.seconds(Value(amount))
    }

    /// Creates a new `TimeAmount` for the given amount of minutes.
    ///
    /// - parameters:
    ///     - amount: the amount of minutes this `TimeAmount` represents.
    /// - returns: the `TimeAmount` for the given amount.
    public static func minutes(_ amount: Value) -> SWIMTimeAmount {
        SWIMTimeAmount(amount * 1000 * 1000 * 1000 * 60)
    }

    public static func minutes(_ amount: Int) -> SWIMTimeAmount {
        self.minutes(Value(amount))
    }

    /// Creates a new `TimeAmount` for the given amount of hours.
    ///
    /// - parameters:
    ///     - amount: the amount of hours this `TimeAmount` represents.
    /// - returns: the `TimeAmount` for the given amount.
    public static func hours(_ amount: Value) -> SWIMTimeAmount {
        SWIMTimeAmount(amount * 1000 * 1000 * 1000 * 60 * 60)
    }

    public static func hours(_ amount: Int) -> SWIMTimeAmount {
        self.hours(Value(amount))
    }
}

extension SWIMTimeAmount: Comparable {
    public static func < (lhs: SWIMTimeAmount, rhs: SWIMTimeAmount) -> Bool {
        lhs.nanoseconds < rhs.nanoseconds
    }

    public static func == (lhs: SWIMTimeAmount, rhs: SWIMTimeAmount) -> Bool {
        lhs.nanoseconds == rhs.nanoseconds
    }
}

/// "Pretty" time amount rendering, useful for human readable durations in tests
extension SWIMTimeAmount: CustomStringConvertible {
    public var description: String {
        "TimeAmount(\(self.prettyDescription), nanoseconds: \(self.nanoseconds))"
    }

    public var prettyDescription: String {
        self.prettyDescription()
    }

    public func prettyDescription(precision: Int = 2) -> String {
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
            let unit = chooseUnit(remainingNanos)

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

    private func chooseUnit(_ ns: Value) -> TimeUnit {
        // @formatter:off
        if ns / TimeUnit.days.rawValue > 0 {
            return TimeUnit.days
        } else if ns / TimeUnit.hours.rawValue > 0 {
            return TimeUnit.hours
        } else if ns / TimeUnit.minutes.rawValue > 0 {
            return TimeUnit.minutes
        } else if ns / TimeUnit.seconds.rawValue > 0 {
            return TimeUnit.seconds
        } else if ns / TimeUnit.milliseconds.rawValue > 0 {
            return TimeUnit.milliseconds
        } else if ns / TimeUnit.microseconds.rawValue > 0 {
            return TimeUnit.microseconds
        } else {
            return TimeUnit.nanoseconds
        }
        // @formatter:on
    }

    /// Represents number of nanoseconds within given time unit
    enum TimeUnit: Value {
        // @formatter:off
        case days = 86_400_000_000_000
        case hours = 3_600_000_000_000
        case minutes = 60_000_000_000
        case seconds = 1_000_000_000
        case milliseconds = 1_000_000
        case microseconds = 1000
        case nanoseconds = 1
        // @formatter:on

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

        func timeAmount(_ amount: Int) -> SWIMTimeAmount {
            switch self {
            case .nanoseconds: return .nanoseconds(Value(amount))
            case .microseconds: return .microseconds(Value(amount))
            case .milliseconds: return .milliseconds(Value(amount))
            case .seconds: return .seconds(Value(amount))
            case .minutes: return .minutes(Value(amount))
            case .hours: return .hours(Value(amount))
            case .days: return .hours(Value(amount) * 24)
            }
        }
    }
}

public extension SWIMTimeAmount {
    /// The microseconds representation of the `TimeAmount`.
    var microseconds: Int64 {
        self.nanoseconds / SWIMTimeAmount.TimeUnit.microseconds.rawValue
    }

    /// The milliseconds representation of the `TimeAmount`.
    var milliseconds: Int64 {
        self.nanoseconds / SWIMTimeAmount.TimeUnit.milliseconds.rawValue
    }

    /// The seconds representation of the `TimeAmount`.
    var seconds: Int64 {
        self.nanoseconds / SWIMTimeAmount.TimeUnit.seconds.rawValue
    }

    /// The minutes representation of the `TimeAmount`.
    var minutes: Int64 {
        self.nanoseconds / SWIMTimeAmount.TimeUnit.minutes.rawValue
    }

    /// The hours representation of the `TimeAmount`.
    var hours: Int64 {
        self.nanoseconds / SWIMTimeAmount.TimeUnit.hours.rawValue
    }

    /// The days representation of the `TimeAmount`.
    var days: Int64 {
        self.nanoseconds / SWIMTimeAmount.TimeUnit.days.rawValue
    }

    /// Returns true if the time amount is "effectively infinite" (equal to `TimeAmount.effectivelyInfinite`)
    var isEffectivelyInfinite: Bool {
        self == SWIMTimeAmount.effectivelyInfinite
    }
}

public extension SWIMTimeAmount {
    /// Largest time amount expressible using this type.
    /// Roughly equivalent to 292 years, which for the intents and purposes of this type can serve as "infinite".
    static var effectivelyInfinite: SWIMTimeAmount {
        SWIMTimeAmount(Value.max)
    }

    /// Smallest non-negative time amount.
    static var zero: SWIMTimeAmount {
        SWIMTimeAmount(0)
    }
}

public extension SWIMTimeAmount {
    static func + (lhs: SWIMTimeAmount, rhs: SWIMTimeAmount) -> SWIMTimeAmount {
        .nanoseconds(lhs.nanoseconds + rhs.nanoseconds)
    }

    static func - (lhs: SWIMTimeAmount, rhs: SWIMTimeAmount) -> SWIMTimeAmount {
        .nanoseconds(lhs.nanoseconds - rhs.nanoseconds)
    }

    static func * (lhs: SWIMTimeAmount, rhs: Int) -> SWIMTimeAmount {
        SWIMTimeAmount(lhs.nanoseconds * Value(rhs))
    }

    static func * (lhs: SWIMTimeAmount, rhs: Double) -> SWIMTimeAmount {
        SWIMTimeAmount(Int64(Double(lhs.nanoseconds) * rhs))
    }

    static func / (lhs: SWIMTimeAmount, rhs: Int) -> SWIMTimeAmount {
        SWIMTimeAmount(lhs.nanoseconds / Value(rhs))
    }

    static func / (lhs: SWIMTimeAmount, rhs: Double) -> SWIMTimeAmount {
        SWIMTimeAmount(Int64(Double(lhs.nanoseconds) / rhs))
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Deadline

// TODO: Deadline based on https://github.com/apple/swift-nio/pull/770/files

/// Represents a point in time.
///
/// Equivalent to `NIO.Deadline`.
///
/// Stores the time in nanoseconds as returned by `DispatchTime.now().uptimeNanoseconds`
///
/// `SWIMDeadline` allow chaining multiple tasks with the same deadline without needing to
/// compute new timeouts for each step
///
/// ```
/// func doSomething(deadline: SWIMDeadline) -> EventLoopFuture<Void> {
///     return step1(deadline: deadline).then {
///         step2(deadline: deadline)
///     }
/// }
/// doSomething(deadline: .now() + .seconds(5))
/// ```
///
/// - note: `SWIMDeadline` should not be used to represent a time interval
public struct SWIMDeadline: Equatable, Hashable {
    public typealias Value = Int64

    /// The nanoseconds since boot representation of the `Deadline`.
    public let uptimeNanoseconds: Value

    public init(_ uptimeNanoseconds: Value) {
        self.uptimeNanoseconds = uptimeNanoseconds
    }

    public static let distantPast = SWIMDeadline(0)
    public static let distantFuture = SWIMDeadline(Value.max)

    public static func now() -> SWIMDeadline {
        uptimeNanoseconds(SWIMDeadline.Value(DispatchTime.now().uptimeNanoseconds))
    }

    public static func uptimeNanoseconds(_ nanoseconds: Value) -> SWIMDeadline {
        SWIMDeadline(nanoseconds)
    }
}

extension SWIMDeadline: Comparable {
    public static func < (lhs: SWIMDeadline, rhs: SWIMDeadline) -> Bool {
        lhs.uptimeNanoseconds < rhs.uptimeNanoseconds
    }

    public static func > (lhs: SWIMDeadline, rhs: SWIMDeadline) -> Bool {
        lhs.uptimeNanoseconds > rhs.uptimeNanoseconds
    }
}

extension SWIMDeadline: CustomStringConvertible {
    public var description: String {
        self.uptimeNanoseconds.description
    }
}

extension SWIMDeadline {
    public static func - (lhs: SWIMDeadline, rhs: SWIMDeadline) -> SWIMTimeAmount {
        .nanoseconds(SWIMTimeAmount.Value(lhs.uptimeNanoseconds) - SWIMTimeAmount.Value(rhs.uptimeNanoseconds))
    }

    public static func + (lhs: SWIMDeadline, rhs: SWIMTimeAmount) -> SWIMDeadline {
        if rhs.nanoseconds < 0 {
            return SWIMDeadline(lhs.uptimeNanoseconds - SWIMDeadline.Value(rhs.nanoseconds.magnitude))
        } else {
            return SWIMDeadline(lhs.uptimeNanoseconds + SWIMDeadline.Value(rhs.nanoseconds.magnitude))
        }
    }

    public static func - (lhs: SWIMDeadline, rhs: SWIMTimeAmount) -> SWIMDeadline {
        if rhs.nanoseconds < 0 {
            return SWIMDeadline(lhs.uptimeNanoseconds + SWIMDeadline.Value(rhs.nanoseconds.magnitude))
        } else {
            return SWIMDeadline(lhs.uptimeNanoseconds - SWIMDeadline.Value(rhs.nanoseconds.magnitude))
        }
    }
}

public extension SWIMDeadline {
    static func fromNow(_ amount: SWIMTimeAmount) -> SWIMDeadline {
        .now() + amount
    }

    /// - Returns: true if the deadline is still pending with respect to the passed in `now` time instant
    func hasTimeLeft() -> Bool {
        self.hasTimeLeft(until: .now())
    }

    func hasTimeLeft(until: SWIMDeadline) -> Bool {
        !self.isBefore(until)
    }

    /// - Returns: true if the deadline is overdue with respect to the passed in `now` time instant
    func isOverdue() -> Bool {
        self.isBefore(.now())
    }

    func isBefore(_ until: SWIMDeadline) -> Bool {
        self.uptimeNanoseconds < until.uptimeNanoseconds
    }

    var timeLeft: SWIMTimeAmount {
        .nanoseconds(self.uptimeNanoseconds - SWIMDeadline.now().uptimeNanoseconds)
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Clocks

public struct WallTimeClock: Comparable {
    internal let timestamp: UInt64

    public static let distantFuture: WallTimeClock = WallTimeClock(timestamp: DispatchTime.distantFuture.uptimeNanoseconds)
    public static let distantPast: WallTimeClock = WallTimeClock(timestamp: 0)

    public static func now() -> WallTimeClock {
        self.init(timestamp: DispatchTime.now().uptimeNanoseconds)
    }

    init(timestamp: UInt64) {
        self.timestamp = timestamp
    }

    public static func < (lhs: WallTimeClock, rhs: WallTimeClock) -> Bool {
        lhs.timestamp < rhs.timestamp
    }

    public static func == (lhs: WallTimeClock, rhs: WallTimeClock) -> Bool {
        lhs.timestamp == rhs.timestamp
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: TimeSpec

#if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
import Darwin
#else
import Glibc
#endif

// MARK: utilities to convert between TimeAmount and C timespec

private let NANOS = 1_000_000_000

/// :nodoc: Not intended for general use. TODO: Make internal if possible.
public typealias TimeSpec = timespec

// TODO: move to Time.swift?

/// :nodoc: Not intended for general use. TODO: Make internal if possible.
public extension TimeSpec {
    static func from(timeAmount amount: SWIMTimeAmount) -> timespec {
        let seconds = Int(amount.nanoseconds) / NANOS
        let nanos = Int(amount.nanoseconds) % NANOS
        var time = timespec()
        time.tv_sec = seconds
        time.tv_nsec = nanos
        return time
    }

    static func + (a: timespec, b: timespec) -> timespec {
        let totalNanos = a.toNanos() + b.toNanos()
        let seconds = totalNanos / NANOS
        var result = timespec()
        result.tv_sec = seconds
        result.tv_nsec = totalNanos % NANOS
        return result
    }

    func toNanos() -> Int {
        self.tv_nsec + (self.tv_sec * NANOS)
    }
}

extension TimeSpec: Comparable {
    public static func < (lhs: TimeSpec, rhs: TimeSpec) -> Bool {
        lhs.tv_sec < rhs.tv_sec || (lhs.tv_sec == rhs.tv_sec && lhs.tv_nsec < rhs.tv_nsec)
    }

    public static func == (lhs: TimeSpec, rhs: TimeSpec) -> Bool {
        lhs.tv_sec == rhs.tv_sec && lhs.tv_nsec == lhs.tv_nsec
    }
}
