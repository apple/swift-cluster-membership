//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Cluster Membership open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift Cluster Membership project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of Swift Cluster Membership project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import ClusterMembership
import Logging
import NIO
import NIOCore
import SWIM
import ServiceLifecycle

public struct SWIMNIOService: Service {
    public let shell: SWIMNIOShell
    public let channel: NIOAsyncChannel<AddressedEnvelope<ByteBuffer>, AddressedEnvelope<ByteBuffer>>

    public var node: Node { self.shell.node }
    public var metrics: SWIM.Metrics.ShellMetrics { self.shell.metrics }
    public var log: Logger { self.shell.log }

    public init(
        node: Node,
        settings: SWIMNIO.Settings,
        channel: NIOAsyncChannel<AddressedEnvelope<ByteBuffer>, AddressedEnvelope<ByteBuffer>>,
        onMemberStatusChange: @escaping @Sendable (SWIM.MemberStatusChangedEvent) -> Void = { _ in () }
    ) {
        self.channel = channel
        self.shell = SWIMNIOShell(
            node: node,
            settings: settings,
            onMemberStatusChange: onMemberStatusChange
        )
    }

    public func run() async throws {
        try await withTaskCancellationOrGracefulShutdownHandler {
            try await self.shell.run(channel: self.channel)
        } onCancelOrGracefulShutdown: {
            self.channel.channel.close(promise: nil)
        }
        await self.shell.receiveShutdown()
    }
}
