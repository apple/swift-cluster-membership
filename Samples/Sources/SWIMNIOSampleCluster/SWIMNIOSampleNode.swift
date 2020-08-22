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
import SWIMNIO
import NIO
import Logging


struct SampleSWIMNIONode {
    let port: Int
    var settings: SWIM.Settings

    let group: EventLoopGroup

    init(port: Int, settings: SWIM.Settings, group: EventLoopGroup) {
        self.port = port
        self.settings = settings
        self.group = group
    }

    func start() {
        let bootstrap = DatagramBootstrap(group: group)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelInitializer { channel in
                return channel.pipeline
                    .addHandler(SWIMNIOHandler(settings: settings)).flatMap {
                        channel.pipeline.addHandler(SWIMNIOSampleHandler())
                    }
            }

        bootstrap.bind(host: "127.0.0.1", port: port).whenComplete { result in
            switch result {
            case .failure(let error):
                self.settings.logger.error("Error: \(error)")
                () // complete(error)
            default:
                () // complete(nil)
            }
        }
    }

}

final class SWIMNIOSampleHandler: ChannelInboundHandler {
    public typealias InboundIn = SWIM.MemberStatusChangedEvent
    
    let log = Logger(label: "SWIMNIOSampleHandler")
    
    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let change: SWIM.MemberStatusChangedEvent = self.unwrapInboundIn(data)

        self.log.info("SWIM membership change: \(change)")
    }
}
