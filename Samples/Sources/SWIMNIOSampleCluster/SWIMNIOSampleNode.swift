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

import ClusterMembership
import SWIM
import SWIMNIOExample
import NIO
import Logging

struct SampleSWIMNIONode {
    let port: Int
    var settings: SWIMNIO.Settings

    let group: EventLoopGroup

    init(port: Int, settings: SWIMNIO.Settings, group: EventLoopGroup) {
        self.port = port
        self.settings = settings
        self.group = group
    }

    func start() {
        let bootstrap = DatagramBootstrap(group: group)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelInitializer { channel in
                return channel.pipeline
                    .addHandler(SWIMNIOHandler(settings: self.settings)).flatMap {
                        channel.pipeline.addHandler(SWIMNIOSampleHandler())
                    }
            }

        bootstrap.bind(host: "127.0.0.1", port: port).whenComplete { result in
            switch result {
            case .success(let res):
                self.settings.logger.info("Bound to: \(res)")
                ()
            case .failure(let error):
                self.settings.logger.error("Error: \(error)")
                ()
            }
        }
    }

}

final class SWIMNIOSampleHandler: ChannelInboundHandler {
    public typealias InboundIn = SWIM.MemberStatusChangedEvent

    let log = Logger(label: "SWIMNIOSample")

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let change: SWIM.MemberStatusChangedEvent = self.unwrapInboundIn(data)

        // we log each event (in a pretty way)
        self.log.info("Membership status changed: [\(change.member.node)] is now [\(change.status)]", metadata: [
            "swim/member": "\(change.member.node)",
            "swim/member/previousStatus": "\(change.previousStatus.map({"\($0)"}) ?? "unknown")",
            "swim/member/status": "\(change.status)",
        ])
    }
}
