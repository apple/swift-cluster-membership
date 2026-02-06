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
import SWIM
import SWIMNIOExample
import ServiceLifecycle

struct SampleSWIMNIONode: Service {

    let port: Int
    let settings: SWIMNIO.Settings

    let group: EventLoopGroup

    init(port: Int, settings: SWIMNIO.Settings, group: EventLoopGroup) {
        self.port = port
        self.settings = settings
        self.group = group
    }

    func run() async throws {
        try await withGracefulShutdownHandler {
            let bootstrap = DatagramBootstrap(group: group)
                .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .channelInitializer { channel in
                    channel.pipeline
                        .addHandler(SWIMNIOHandler(settings: self.settings)).flatMap {
                            channel.pipeline.addHandler(SWIMNIOSampleHandler())
                        }
                }

            let channel =
                try await bootstrap
                .bind(host: "127.0.0.1", port: port)
                .get()
            do {
                self.settings.logger.info("Bound to: \(channel)")
                try await channel.closeFuture.get()
            } catch {
                self.settings.logger.error("Error: \(error)")
            }

        } onGracefulShutdown: {
            try? group.syncShutdownGracefully()
        }
    }

}

final class SWIMNIOSampleHandler: ChannelInboundHandler {
    typealias InboundIn = SWIM.MemberStatusChangedEvent<SWIM.NIOPeer>

    let log = Logger(label: "SWIMNIOSample")

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let change: SWIM.MemberStatusChangedEvent = self.unwrapInboundIn(data)

        // we log each event (in a pretty way)
        self.log.info(
            "Membership status changed: [\(change.member.node)] is now [\(change.status)]",
            metadata: [
                "swim/member": "\(change.member.node)",
                "swim/member/previousStatus": "\(change.previousStatus.map({"\($0)"}) ?? "unknown")",
                "swim/member/status": "\(change.status)",
            ]
        )
    }
}
