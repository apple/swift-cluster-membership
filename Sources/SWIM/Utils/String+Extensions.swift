//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2018-2019 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: String Interpolation: reflecting:

internal extension String.StringInterpolation {
    mutating func appendInterpolation(reflecting subject: Any?) {
        self.appendLiteral(String(reflecting: subject))
    }

    mutating func appendInterpolation(reflecting subject: Any) {
        self.appendLiteral(String(reflecting: subject))
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: String Interpolation: lineByLine:

internal extension String.StringInterpolation {
    mutating func appendInterpolation(lineByLine subject: [Any]) {
        self.appendLiteral("\n    \(subject.map { "\($0)" }.joined(separator: "\n    "))")
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: String Interpolation: _:orElse:

public extension String.StringInterpolation {
    mutating func appendInterpolation<T>(_ value: T?, orElse defaultValue: String) {
        self.appendLiteral("\(value.map { "\($0)" } ?? defaultValue)")
    }

    mutating func appendInterpolation<T>(optional value: T?) {
        self.appendLiteral("\(value.map { "\($0)" } ?? "nil")")
    }
}
