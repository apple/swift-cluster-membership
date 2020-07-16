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

import ClusterMembership
import Logging
import NIO
import SWIM

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Tracelog: SWIM [tracelog:SWIM]

extension NIOSWIMShell {
    /// Optional "dump all messages" logging.
    ///
    /// Enabled by `SWIM.Settings.traceLogLevel` or `-DTRACELOG_SWIM`
    func tracelog(
        _ type: TraceLogType, message: @autoclosure () -> String,
        file: String = #file, function: String = #function, line: UInt = #line
    ) {
        if let level = self.settings.traceLogLevel {
            self.log.log(
                level: level,
                "\(type.description): \(message())",
                metadata: self.swim.metadata,
                file: file, function: function, line: line
            )
        }
    }

    internal enum TraceLogType: CustomStringConvertible {
        case send(to: Node) // <SWIM.Message>
        case reply(to: Node) // <SWIM.PingResponse>
        case receive(pinged: Node?) // <SWIM.Message>

        static var receive: TraceLogType {
            .receive(pinged: nil)
        }

        static func send(to: SWIMPeerProtocol) -> TraceLogType {
            .send(to: to.node)
        }

        static func reply(to: SWIMPeerProtocol) -> TraceLogType {
            .reply(to: to.node)
        }

        static func receive(pinged: SWIMPeerProtocol) -> TraceLogType {
            .receive(pinged: pinged.node)
        }

        var description: String {
            switch self {
            case .send(let to):
                return "SEND(to:\(to))"
            case .receive(nil):
                return "RECV"
            case .receive(let .some(pinged)):
                return "RECV(pinged:\(pinged))"
            case .reply(let to):
                return "REPL(to:\(to))"
            }
        }
    }
}
