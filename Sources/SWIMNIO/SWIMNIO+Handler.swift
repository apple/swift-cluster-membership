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
import NIOFoundationCompat
import SWIM

final class SWIMProtocolHandler: ChannelDuplexHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = Never
    typealias OutboundIn = SWIM.RemoteMessage
    typealias OutboundOut = ByteBuffer

    private let settings: SWIM.Settings
    private var shell: NIOSWIMShell!

    init(settings: SWIM.Settings) {
        self.settings = settings
        self.shell = nil
    }

    func channelActive(context: ChannelHandlerContext) {
        guard let hostIP = context.channel.localAddress!.ipAddress else {
            fatalError("SWIM requires a known host IP, but was nil! Channel: \(context.channel)")
        }
        guard let hostPort = context.channel.localAddress!.port else {
            fatalError("SWIM requires a known host IP, but was nil! Channel: \(context.channel)")
        }

        let node: Node = .init(protocol: "tcp", host: hostIP, port: hostPort, uid: .random(in: 0 ..< UInt64.max))
        self.shell = .init(settings: self.settings, node: node, channel: context.channel)
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let message = self.unwrapOutboundIn(data)

        // serialize
        do {
            let buffer = try self.serialize(message: message, using: context.channel.allocator)

            // context.write(buffer) // FIXME: write type type manifest
            context.write(self.wrapOutboundOut(buffer), promise: promise)
        } catch {
            self.settings.logger.warning("Write failed: \(error)")
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let bytes = self.unwrapOutboundIn(data)
    }

    private func serialize(message: SWIM.RemoteMessage, using allocator: ByteBufferAllocator) throws -> ByteBuffer {
        let proto = try message.toProto()
        let data = try proto.serializedData()
        let buffer = data.withUnsafeBytes { bytes -> ByteBuffer in
            var buffer = allocator.buffer(capacity: data.count)
            buffer.writeBytes(bytes)
            return buffer
        }
        return buffer
    }
}
