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

//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Metrics API open source project
//
// Copyright (c) 2018-2019 Apple Inc. and the Swift Metrics API project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of Swift Metrics API project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import ClusterMembership
@testable import CoreMetrics
@testable import Metrics
@testable import SWIM
import XCTest

/// Taken directly from swift-metrics's own test package.
///
/// Metrics factory which allows inspecting recorded metrics programmatically.
/// Only intended for tests of the Metrics API itself.
internal final class TestMetrics: MetricsFactory {
    private let lock = NSLock()

    typealias Label = String
    typealias Dimensions = String
    struct FullKey {
        let label: Label
        let dimensions: [(String, String)]
    }

    private var counters = [FullKey: CounterHandler]()
    private var recorders = [FullKey: RecorderHandler]()
    private var timers = [FullKey: TimerHandler]()

    public func makeCounter(label: String, dimensions: [(String, String)]) -> CounterHandler {
        self.make(label: label, dimensions: dimensions, registry: &self.counters, maker: TestCounter.init)
    }

    public func makeRecorder(label: String, dimensions: [(String, String)], aggregate: Bool) -> RecorderHandler {
        let maker = { (label: String, dimensions: [(String, String)]) -> RecorderHandler in
            TestRecorder(label: label, dimensions: dimensions, aggregate: aggregate)
        }
        return self.make(label: label, dimensions: dimensions, registry: &self.recorders, maker: maker)
    }

    public func makeTimer(label: String, dimensions: [(String, String)]) -> TimerHandler {
        self.make(label: label, dimensions: dimensions, registry: &self.timers, maker: TestTimer.init)
    }

    private func make<Item>(label: String, dimensions: [(String, String)], registry: inout [FullKey: Item], maker: (String, [(String, String)]) -> Item) -> Item {
        self.lock.withLock {
            let item = maker(label, dimensions)
            registry[.init(label: label, dimensions: dimensions)] = item
            return item
        }
    }

    func destroyCounter(_ handler: CounterHandler) {
        if let testCounter = handler as? TestCounter {
            self.counters.removeValue(forKey: testCounter.key)
        }
    }

    func destroyRecorder(_ handler: RecorderHandler) {
        if let testRecorder = handler as? TestRecorder {
            self.recorders.removeValue(forKey: testRecorder.key)
        }
    }

    func destroyTimer(_ handler: TimerHandler) {
        if let testTimer = handler as? TestTimer {
            self.timers.removeValue(forKey: testTimer.key)
        }
    }
}

extension TestMetrics.FullKey: Hashable {
    public func hash(into hasher: inout Hasher) {
        self.label.hash(into: &hasher)
        self.dimensions.forEach { dim in
            dim.0.hash(into: &hasher)
            dim.1.hash(into: &hasher)
        }
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.label == rhs.label &&
            Dictionary(uniqueKeysWithValues: lhs.dimensions) == Dictionary(uniqueKeysWithValues: rhs.dimensions)
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Assertions

extension TestMetrics {
    public func expectCounter(metric: Counter) throws -> TestCounter {
        metric.handler as! TestCounter
    }

    public func expectCounter(_ label: String, _ dimensions: [(String, String)] = []) throws -> TestCounter {
        let counter: CounterHandler
        if let c: CounterHandler = self.counters[.init(label: label, dimensions: dimensions)] {
            counter = c
        } else {
            throw TestMetricsError.missingMetric(label: label, dimensions: [])
        }

        guard let testCounter = counter as? TestCounter else {
            throw TestMetricsError.illegalMetricType(metric: counter, expected: "\(TestCounter.self)")
        }

        return testCounter
    }

    public func expectGauge(_ metric: Gauge) throws -> TestRecorder {
        return try self.expectRecorder(metric)
    }

    public func expectGauge(_ label: String, _ dimensions: [(String, String)] = []) throws -> TestRecorder {
        return try self.expectRecorder(label, dimensions)
    }

    public func expectRecorder(_ metric: Recorder) throws -> TestRecorder {
        metric.handler as! TestRecorder
    }

    public func expectRecorder(_ label: String, _ dimensions: [(String, String)] = []) throws -> TestRecorder {
        guard let counter = self.recorders[.init(label: label, dimensions: dimensions)] else {
            throw TestMetricsError.missingMetric(label: label, dimensions: [])
        }
        guard let testRecorder = counter as? TestRecorder else {
            throw TestMetricsError.illegalMetricType(metric: counter, expected: "\(TestRecorder.self)")
        }

        return testRecorder
    }

    public func expectTimer(_ metric: Timer) throws -> TestTimer {
        metric.handler as! TestTimer
    }

    public func expectTimer(_ label: String, _ dimensions: [(String, String)] = []) throws -> TestTimer {
        guard let counter = self.timers[.init(label: label, dimensions: dimensions)] else {
            throw TestMetricsError.missingMetric(label: label, dimensions: [])
        }
        guard let testTimer = counter as? TestTimer else {
            throw TestMetricsError.illegalMetricType(metric: counter, expected: "\(TestTimer.self)")
        }

        return testTimer
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Metric type implementations

protocol TestMetric {
    associatedtype Value

    var key: TestMetrics.FullKey { get }

    var lastValue: Value? { get }
    var last: (Date, Value)? { get }
}

final class TestCounter: TestMetric, CounterHandler, Equatable {
    let id: String
    let label: String
    let dimensions: [(String, String)]

    var key: TestMetrics.FullKey {
        .init(label: self.label, dimensions: self.dimensions)
    }

    let lock = NSLock()
    private var values = [(Date, Int64)]()

    init(label: String, dimensions: [(String, String)]) {
        self.id = NSUUID().uuidString
        self.label = label
        self.dimensions = dimensions
    }

    func increment(by amount: Int64) {
        self.lock.withLock {
            self.values.append((Date(), amount))
        }
        print("adding \(amount) to \(self.label)\(self.dimensions.map { "\($0):\($1)" })")
    }

    func reset() {
        self.lock.withLock {
            self.values = []
        }
        print("resetting \(self.label)")
    }

    var lastValue: Int64? {
        self.lock.withLock {
            values.last?.1
        }
    }

    var last: (Date, Int64)? {
        self.lock.withLock {
            values.last
        }
    }

    public static func == (lhs: TestCounter, rhs: TestCounter) -> Bool {
        lhs.id == rhs.id
    }
}

final class TestRecorder: TestMetric, RecorderHandler, Equatable {
    let id: String
    let label: String
    let dimensions: [(String, String)]
    let aggregate: Bool

    var key: TestMetrics.FullKey {
        .init(label: self.label, dimensions: self.dimensions)
    }

    let lock = NSLock()
    private var values = [(Date, Double)]()

    init(label: String, dimensions: [(String, String)], aggregate: Bool) {
        self.id = NSUUID().uuidString
        self.label = label
        self.dimensions = dimensions
        self.aggregate = aggregate
    }

    func record(_ value: Int64) {
        self.record(Double(value))
    }

    func record(_ value: Double) {
        self.lock.withLock {
            // this may loose precision but good enough as an example
            values.append((Date(), Double(value)))
        }
        print("recording \(value) in \(self.label)\(self.dimensions.map { "\($0):\($1)" })")
    }

    var lastValue: Double? {
        self.lock.withLock {
            values.last?.1
        }
    }

    var last: (Date, Double)? {
        self.lock.withLock {
            values.last
        }
    }

    public static func == (lhs: TestRecorder, rhs: TestRecorder) -> Bool {
        lhs.id == rhs.id
    }
}

final class TestTimer: TestMetric, TimerHandler, Equatable {
    let id: String
    let label: String
    var displayUnit: TimeUnit?
    let dimensions: [(String, String)]

    var key: TestMetrics.FullKey {
        .init(label: self.label, dimensions: self.dimensions)
    }

    let lock = NSLock()
    private var values = [(Date, Int64)]()

    init(label: String, dimensions: [(String, String)]) {
        self.id = NSUUID().uuidString
        self.label = label
        self.displayUnit = nil
        self.dimensions = dimensions
    }

    func preferDisplayUnit(_ unit: TimeUnit) {
        self.lock.withLock {
            self.displayUnit = unit
        }
    }

    func retriveValueInPreferredUnit(atIndex i: Int) -> Double {
        self.lock.withLock {
            let value = values[i].1
            guard let displayUnit = self.displayUnit else {
                return Double(value)
            }
            return Double(value) / Double(displayUnit.scaleFromNanoseconds)
        }
    }

    func recordNanoseconds(_ duration: Int64) {
        self.lock.withLock {
            values.append((Date(), duration))
        }
        print("recording \(duration) in \(self.label)\(self.dimensions.map { "\($0):\($1)" })")
    }

    var lastValue: Int64? {
        self.lock.withLock {
            values.last?.1
        }
    }

    var last: (Date, Int64)? {
        self.lock.withLock {
            values.last
        }
    }

    public static func == (lhs: TestTimer, rhs: TestTimer) -> Bool {
        lhs.id == rhs.id
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        self.lock()
        defer {
            self.unlock()
        }
        return body()
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Errors

enum TestMetricsError: Error {
    case missingMetric(label: String, dimensions: [(String, String)])
    case illegalMetricType(metric: Any, expected: String)
}
