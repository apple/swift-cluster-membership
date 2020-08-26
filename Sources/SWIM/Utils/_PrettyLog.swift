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

import struct Foundation.Calendar
import struct Foundation.Date
import class Foundation.DateFormatter
import struct Foundation.Locale
import Logging

/// Pretty log formatter which prints log lines in the following multi line format,
/// listing every metadata element in it's own, `//`-prefixed, line as well as pretty printing connections if set as `Logger.MetadataValue`.
///
/// Example output:
///
/// ```
/// SWIMNIOSample: [2020-08-25 0:7:59.8420] [info] [Example.swift:66] Membership status changed: [udp://127.0.0.1:7001#7015602685756068157] is now [alive(incarnation: 0)]
//// metadata:
//// "swim/member": udp://127.0.0.1:7001#7015602685756068157
//// "swim/member/previousStatus": unknown
//// "swim/member/status": alive(incarnation: 0)
/// ```
///
/// Pro tip: you may want to use a coloring terminal application, which colors lines prefixed with `//` with a slightly different color,
/// which makes visually parsing metadata vs. log message lines even more visually pleasing.
public struct _SWIMPrettyMetadataLogHandler: LogHandler {
    let CONSOLE_RESET = "\u{001B}[0;0m"
    let CONSOLE_BOLD = "\u{001B}[1m"

    let label: String

    /// :nodoc:
    public init(_ label: String) {
        self.label = label
    }

    public subscript(metadataKey _: String) -> Logger.Metadata.Value? {
        get {
            [:]
        }
        set {}
    }

    public var metadata: Logger.Metadata = [:]
    public var logLevel: Logger.Level = .trace

    public func log(level: Logger.Level,
                    message: Logger.Message,
                    metadata: Logger.Metadata?,
                    source: String,
                    file: String,
                    function: String,
                    line: UInt) {
        var metadataString: String = ""
        if let metadata = metadata {
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
        let date = self._createFormatter().string(from: Date())
        let file = file.split(separator: "/").last ?? ""
        let line = line
        print("\(self.CONSOLE_BOLD)\(self.label)\(self.CONSOLE_RESET): [\(date)] [\(level)] [\(file):\(line)] \(message)\(metadataString)")
    }

    internal func prettyPrint(metadata: Logger.MetadataValue) -> String {
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
                valueDescription += "\(CONSOLE_BOLD)\(k)\(CONSOLE_RESET): \(self.prettyPrint(metadata: metadata[k]!))"
            }
        }

        return valueDescription
    }

    private func _createFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "y-MM-dd H:m:ss.SSSS"
        formatter.locale = Locale(identifier: "en_US")
        formatter.calendar = Calendar(identifier: .gregorian)
        return formatter
    }
}
