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
    public func metadata(_ additional: Logger.Metadata) -> Logger.Metadata {
        var metadata = self.metadata
        metadata.merge(additional, uniquingKeysWith: { _, r in r })
        return metadata
    }

    /// While the SWIM.Instance is not meant to be logging by itself, it does offer metadata for loggers to use.
    public var metadata: Logger.Metadata {
        [
            "swim/protocolPeriod": "\(self.protocolPeriod)",
            "swim/timeoutSuspectsBeforePeriodMax": "\(self.timeoutSuspectsBeforePeriodMax)",
            "swim/timeoutSuspectsBeforePeriodMin": "\(self.timeoutSuspectsBeforePeriodMin)",
            "swim/incarnation": "\(self.incarnation)",
            "swim/members/all": Logger.Metadata.Value.array(self.allMembers.map { "\($0)" }),
            "swim/members/toPing": Logger.Metadata.Value.array(self.membersToPing.map { "\($0)" }),
            "swim/member/count": "\(self.notDeadMemberCount)",
            "swim/suspects/count": "\(self.suspects.count)",
        ]
    }
}
