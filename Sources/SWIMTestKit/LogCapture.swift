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

import Foundation
import NIO
import Synchronization
import Testing

import class Foundation.NSLock

@testable import Logging

/// Testing only utility: Captures all log statements for later inspection.
public final class LogCapture: Sendable {
  private let _logs: Mutex<[CapturedLogMessage]> = .init([])

  let settings: Settings
  private let captureLabel: Mutex<String> = .init("")

  public init(settings: Settings = .init()) {
    self.settings = settings
  }

  public func logger(label: String) -> Logger {
    self.captureLabel.withLock { $0 = label }
    return Logger(label: "LogCapture(\(label))", LogCaptureLogHandler(label: label, self))
  }

  func append(_ log: CapturedLogMessage) {
    self._logs.withLock {
      $0.append(log)
    }
  }

  public var logs: [CapturedLogMessage] {
    self._logs.withLock { $0 }
  }

  @discardableResult
  public func log(
    grep: String,
    within: Duration = .seconds(10),
    sourceLocation: SourceLocation = #_sourceLocation
  ) async throws -> CapturedLogMessage {
    let startTime = ContinuousClock.now
    let deadline = startTime.advanced(by: within)
    func timeExceeded() -> Bool {
      ContinuousClock.now > deadline
    }
    while !timeExceeded() {
      let logs = self.logs
      if let log = logs.first(where: { log in "\(log)".contains(grep) }) {
        return log  // ok, found it!
      }

      try await Task.sleep(for: .seconds(1))
    }

    throw LogCaptureError(
      message: "After \(within), logs still did not contain: [\(grep)]",
      sourceLocation: sourceLocation
    )
  }
}

extension LogCapture {
  public struct Settings: Sendable {
    public init() {}

    public var minimumLogLevel: Logger.Level = .trace

    public var grep: Set<String> = []

    /// Do not capture log messages which include the following strings.
    public var excludeGrep: Set<String> = []

    public var ignoredMetadata: Set<String> = []
  }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: XCTest integrations and helpers

/// ### Warning
/// This handler uses locks for each and every operation.
extension LogCapture {
  public func printLogs() {
    for log in self.logs {
      var metadataString: String = ""
      var node: String = ""
      if var metadata = log.metadata {
        if let n = metadata.removeValue(forKey: "swim/node") {
          node = "[\(n)]"
        }

        metadata.removeValue(forKey: "label")
        self.settings.ignoredMetadata.forEach { ignoreKey in
          metadata.removeValue(forKey: ignoreKey)
        }
        if !metadata.isEmpty {
          metadataString = "\n// metadata:\n"
          for key in metadata.keys.sorted() {
            let value: Logger.MetadataValue = metadata[key]!
            let valueDescription = self.prettyPrint(metadata: value)

            var allString = "\n// \"\(key)\": \(valueDescription)"
            if allString.contains("\n") {
              allString = String(
                allString.split(separator: "\n").map { valueLine in
                  if valueLine.starts(with: "// ") {
                    return "\(valueLine)\n"
                  } else {
                    return "// \(valueLine)\n"
                  }
                }.joined(separator: "")
              )
            }
            metadataString.append(allString)
          }
          metadataString = String(metadataString.dropLast(1))
        }
      }
      let date = Self._createFormatter().string(from: log.date)
      let file = log.file.split(separator: "/").last ?? ""
      let line = log.line
      let label = self.captureLabel.withLock { $0 }
      print(
        "[\(label)][\(date)] [\(file):\(line)]\(node) [\(log.level)] \(log.message)\(metadataString)"
      )
    }
  }

  public static func _createFormatter() -> DateFormatter {
    let formatter = DateFormatter()
    formatter.dateFormat = "y-MM-dd H:m:ss.SSSS"
    formatter.locale = Locale(identifier: "en_US")
    formatter.calendar = Calendar(identifier: .gregorian)
    return formatter
  }

  internal func prettyPrint(metadata: Logger.MetadataValue) -> String {
    let CONSOLE_RESET = "\u{001B}[0;0m"
    let CONSOLE_BOLD = "\u{001B}[1m"

    var valueDescription = ""
    switch metadata {
    case .string(let string):
      valueDescription = string
    case .stringConvertible(let convertible):
      valueDescription = convertible.description
    case .array(let array):
      valueDescription = "\n  \(array.map { "\($0)" }.joined(separator: "\n  "))"
    case .dictionary(let metadata):
      for k in metadata.keys {
        valueDescription +=
          "\(CONSOLE_BOLD)\(k)\(CONSOLE_RESET): \(self.prettyPrint(metadata: metadata[k]!))"
      }
    }

    return valueDescription
  }
}

public struct CapturedLogMessage: Sendable {
  public let date: Date
  public let level: Logger.Level
  public var message: Logger.Message
  public var metadata: Logger.Metadata?
  public let file: String
  public let function: String
  public let line: UInt
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: LogCapture LogHandler

struct LogCaptureLogHandler: LogHandler {
  let label: String
  let capture: LogCapture

  init(label: String, _ capture: LogCapture) {
    self.label = label
    self.capture = capture
  }

  public func log(
    level: Logger.Level, message: Logger.Message, metadata: Logger.Metadata?, file: String,
    function: String, line: UInt
  ) {
    guard
      self.capture.settings.grep.isEmpty
        || self.capture.settings.grep.contains(where: { "\(message)".contains($0) })
    else {
      return  // log was included explicitly
    }
    guard !self.capture.settings.excludeGrep.contains(where: { "\(message)".contains($0) }) else {
      return  // log was excluded explicitly
    }

    let date = Date()
    var _metadata: Logger.Metadata = self.metadata
    _metadata.merge(metadata ?? [:], uniquingKeysWith: { _, r in r })
    _metadata["label"] = "\(self.label)"

    self.capture.append(
      CapturedLogMessage(
        date: date, level: level, message: message, metadata: _metadata, file: file,
        function: function, line: line))
  }

  public subscript(metadataKey metadataKey: String) -> Logger.Metadata.Value? {
    get {
      self.metadata[metadataKey]
    }
    set {
      self.metadata[metadataKey] = newValue
    }
  }

  public var metadata: Logging.Logger.Metadata = [:]

  public var logLevel: Logger.Level {
    get {
      self.capture.settings.minimumLogLevel
    }
    set {
      // ignore, we always collect all logs
    }
  }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Should matchers

extension LogCapture {
  /// Asserts that a message matching the query requirements was captures *already* (without waiting for it to appear)
  ///
  /// - Parameter message: can be surrounded like `*what*` to query as a "contains" rather than an == on the captured logs.
  @discardableResult
  public func shouldContain(
    prefix: String? = nil,
    message: String? = nil,
    grep: String? = nil,
    at level: Logger.Level? = nil,
    expectedFile: String? = nil,
    expectedLine: Int = -1,
    failTest: Bool = true,
    sourceLocation: SourceLocation = #_sourceLocation
  ) throws -> CapturedLogMessage {
    precondition(
      prefix != nil || message != nil || grep != nil || level != nil || level != nil
        || expectedFile != nil, "At least one query parameter must be not `nil`!")

    let found = self.logs.lazy
      .filter { log in
        if let expected = message {
          if expected.first == "*", expected.last == "*" {
            return "\(log.message)".contains(expected.dropFirst().dropLast())
          } else {
            return expected == "\(log.message)"
          }
        } else {
          return true
        }
      }.filter { log in
        if let expected = prefix {
          return "\(log.message)".starts(with: expected)
        } else {
          return true
        }
      }.filter { log in
        if let expected = grep {
          return "\(log)".contains(expected)
        } else {
          return true
        }
      }.filter { log in
        if let expected = level {
          return log.level == expected
        } else {
          return true
        }
      }.filter { log in
        if let expected = expectedFile {
          return expected == "\(log.file)"
        } else {
          return true
        }
      }.filter { log in
        if expectedLine > -1 {
          return log.line == expectedLine
        } else {
          return true
        }
      }.first

    if let found = found {
      return found
    } else {
      let query = [
        prefix.map {
          "prefix: \"\($0)\""
        },
        message.map {
          "message: \"\($0)\""
        },
        grep.map {
          "grep: \"\($0)\""
        },
        level.map {
          "level: \($0)"
        } ?? "",
        expectedFile.map {
          "expectedFile: \"\($0)\""
        },
        (expectedLine > -1 ? Optional(expectedLine) : nil).map {
          "expectedLine: \($0)"
        },
      ].compactMap {
        $0
      }
      .joined(separator: ", ")

      let message = """
        Did not find expected log, matching query: 
            [\(query)]
        in captured logs at \(sourceLocation)
        """
      if failTest {
        Issue.record(
          .init(rawValue: message),
          sourceLocation: sourceLocation
        )
      }

      throw LogCaptureError(
        message: message,
        sourceLocation: sourceLocation
      )
    }
  }

  public func grep(_ string: String, metadata metadataQuery: [String: String] = [:])
    -> [CapturedLogMessage]
  {
    self.logs.filter {
      guard "\($0)".contains(string) else {
        // mismatch, exclude it
        return false
      }

      if metadataQuery.isEmpty {
        return true
      }

      let metas = $0.metadata ?? [:]
      for (queryKey, queryValue) in metadataQuery {
        if let value = metas[queryKey] {
          if queryValue != "\(value)" {
            // mismatch, exclude it
            return false
          }  // ok, continue checking other keys
        } else {
          // key did not exist
          return false
        }
      }

      return true
    }
  }
}

internal struct LogCaptureError: Error, CustomStringConvertible {
  let message: String
  let sourceLocation: SourceLocation
  var description: String {
    "LogCaptureError(\(message) with at \(sourceLocation)"
  }
}
