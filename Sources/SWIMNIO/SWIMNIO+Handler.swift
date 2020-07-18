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
import Logging
import NIO
import NIOFoundationCompat
import SWIM

public final class SWIMProtocolHandler: ChannelDuplexHandler {
    public typealias InboundIn = ByteBuffer
    public typealias InboundOut = Never
    public typealias OutboundIn = SWIM.Message
    public typealias OutboundOut = ByteBuffer

    private let settings: SWIM.Settings
    private var log: Logger {
        self.settings.logger
    }

    private let group: EventLoopGroup!
    private var shell: NIOSWIMShell!

    public init(settings: SWIM.Settings, group: EventLoopGroup, shell: NIOSWIMShell? = nil) {
        self.settings = settings
        self.group = group
        self.shell = shell
    }

    public func channelActive(context: ChannelHandlerContext) {
        guard self.shell == nil else {
            // assume initialized
            return
        }

        guard let hostIP = context.channel.localAddress!.ipAddress else {
            fatalError("SWIM requires a known host IP, but was nil! Channel: \(context.channel)")
        }
        guard let hostPort = context.channel.localAddress!.port else {
            fatalError("SWIM requires a known host IP, but was nil! Channel: \(context.channel)")
        }

        let node: Node = .init(protocol: "udp", host: hostIP, port: hostPort, uid: .random(in: 0 ..< UInt64.max))
        self.shell = NIOSWIMShell(
            settings: self.settings,
            node: node,
            channel: context.channel,
            makeClient: { _ in
                let bootstrap = DatagramBootstrap(group: self.group)
                    .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
                    .channelInitializer { channel in
                        channel.pipeline.addHandler(SWIMProtocolHandler(settings: self.settings, group: self.group, shell: self.shell))
                    }

                let channel = bootstrap.bind(host: "127.0.0.1", port: .random(in: 1000 ..< 9999))
                // FIXME: channel.connect(to: .v4())
                return channel // FIXME?
            }
        )
    }

    public func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let message = self.unwrapOutboundIn(data)

        // serialize
        do {
            let buffer = try self.serialize(message: message, using: context.channel.allocator)

            // context.write(buffer) // FIXME: write type type manifest
            context.write(self.wrapOutboundOut(buffer), promise: promise)
            context.flush()
        } catch {
            self.settings.logger.warning("Write failed: \(error)")
        }
    }

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard let remoteAddress = context.remoteAddress else {
            fatalError("No remote address during channelRead! Context: \(context)")
        }

        do {
            var bytes = self.unwrapInboundIn(data)
            // FIXME: framing!!!!
            var proto = ProtoSWIMMessage()

            try proto.merge(serializedData: bytes.readData(length: bytes.readableBytes)!) // FIXME: fix the !
            let message = try SWIM.Message(fromProto: proto)

            let node: Node = Node(protocol: "udp", host: remoteAddress.ipAddress!, port: remoteAddress.port!, uid: nil) // FIXME: fix the ! // FIXME: has no concept of UUIDs
            self.shell.eventLoop.scheduleTask(in: .seconds(0)) { // FIXME: a bit ugly
                self.shell.receiveMessage(message: message, from: node)
            }
        } catch {
            self.log.error("Failure: \(error)")
        }
    }

    private func serialize(message: SWIM.Message, using allocator: ByteBufferAllocator) throws -> ByteBuffer {
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
