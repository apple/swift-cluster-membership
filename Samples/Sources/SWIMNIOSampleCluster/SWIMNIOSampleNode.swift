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
        let bootstrap = DatagramBootstrap(group: group)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)

        let asyncChannel = try await bootstrap.bind(
            host: "127.0.0.1",
            port: port
        ) { channel in
            do {
                let asyncChannel = try NIOAsyncChannel<AddressedEnvelope<ByteBuffer>, AddressedEnvelope<ByteBuffer>>(
                    wrappingChannelSynchronously: channel
                )
                return channel.eventLoop.makeSucceededFuture(asyncChannel)
            } catch {
                return channel.eventLoop.makeFailedFuture(error)
            }
        }

        let node = Node(protocol: "udp", host: "127.0.0.1", port: port, uid: .random(in: 1..<UInt64.max))
        var settings = self.settings
        settings.node = node
        let logger = settings.logger

        let service = SWIMNIOService(
            node: node,
            settings: settings,
            channel: asyncChannel,
            onMemberStatusChange: { event in
                logger.info(
                    "Membership status changed: [\(event.member.node)] is now [\(event.status)]",
                    metadata: [
                        "swim/member": "\(event.member.node)",
                        "swim/member/previousStatus": "\(event.previousStatus.map({"\($0)"}) ?? "unknown")",
                        "swim/member/status": "\(event.status)",
                    ]
                )
            }
        )

        self.settings.logger.info("Bound to: \(asyncChannel.channel)")
        try await service.run()
    }

}
