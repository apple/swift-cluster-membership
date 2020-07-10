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

import ClusterMembership
import Logging

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: SWIM Logging Metadata

extension SWIM.Instance {
    /// While the SWIM.Instance is not meant to be logging by itself, it does offer metadata for loggers to use.
    var metadata: Logger.Metadata {
        [
            "swim/protocolPeriod": "\(self.protocolPeriod)",
            "swim/timeoutSuspectsBeforePeriodMax": "\(self.timeoutSuspectsBeforePeriodMax)",
            "swim/timeoutSuspectsBeforePeriodMin": "\(self.timeoutSuspectsBeforePeriodMin)",
            "swim/incarnation": "\(self.incarnation)",
            "swim/membersToPing": Logger.Metadata.Value.array(self.membersToPing.map { "\($0)" }),
            "swim/member/count": "\(self.memberCount)",
            "swim/suspects/count": "\(self.suspects.count)",
        ]
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Tracelog: SWIM [tracelog:SWIM]

extension NIOSWIMShell {
    /// Optional "dump all messages" logging.
    ///
    /// Enabled by `SWIM.Settings.traceLogLevel` or `-DTRACELOG_SWIM`
    func tracelog(
        _ context: SWIMContext, _ type: TraceLogType, message: Any,
        file: String = #file, function: String = #function, line: UInt = #line
    ) {
        if let level = self.settings.traceLogLevel {
            context.log.log(
                level: level,
                "\(type.description): \(message)",
                metadata: self.swim.metadata,
                file: file, function: function, line: line
            )
        }
    }

    internal enum TraceLogType: CustomStringConvertible {
        case reply(to: Peer<SWIM.PingResponse>)
        case receive(pinged: Peer<SWIM.Message>?)

        static var receive: TraceLogType {
            .receive(pinged: nil)
        }

        var description: String {
            switch self {
            case .receive(nil):
                return "RECV"
            case .receive(let .some(pinged)):
                return "RECV(pinged:\(pinged.node))"
            case .reply(let to):
                return "REPL(to:\(to.node))"
            }
        }
    }
}
