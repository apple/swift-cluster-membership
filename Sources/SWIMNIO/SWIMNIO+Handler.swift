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
    public typealias InboundIn = AddressedEnvelope<ByteBuffer>
    public typealias InboundOut = Never
    public typealias OutboundIn = WriteCommand
    public typealias OutboundOut = AddressedEnvelope<ByteBuffer>

    let settings: SWIM.Settings
    var log: Logger {
        self.settings.logger
    }

    // initialized in channelActive
    var shell: SWIMNIOShell! = nil

    var pendingReplyCallbacks: [SWIM.SequenceNr: (Result<SWIM.Message, Error>) -> Void]

    public init(settings: SWIM.Settings) {
        self.settings = settings
        self.pendingReplyCallbacks = [:]
    }

    public func channelActive(context: ChannelHandlerContext) {
        guard let hostIP = context.channel.localAddress!.ipAddress else {
            fatalError("SWIM requires a known host IP, but was nil! Channel: \(context.channel)")
        }
        guard let hostPort = context.channel.localAddress!.port else {
            fatalError("SWIM requires a known host IP, but was nil! Channel: \(context.channel)")
        }

        let node: Node = .init(protocol: "udp", host: hostIP, port: hostPort, uid: .random(in: 0 ..< UInt64.max))
        self.shell = SWIMNIOShell(
            settings: self.settings,
            node: node,
            channel: context.channel,
            makeClient: { _ in
//                let bootstrap = DatagramBootstrap(group: self.group)
//                    .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
//                    .channelInitializer { channel in
//                        channel.pipeline.addHandler(SWIMProtocolHandler(settings: self.settings))
//                    }
//
//                let channel = bootstrap.bind(host: "127.0.0.1", port: .random(in: 1000 ..< 9999))
                return context.eventLoop.makeSucceededFuture(context.channel)
            }
        )

        self.log.warning("channel active", metadata: [
            "channel": "\(context.channel)",
        ])
    }

    public func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let writeCommand = self.unwrapOutboundIn(data)

        self.log.warning("write command", metadata: [
            "write/message": "\(writeCommand.message)",
            "write/recipient": "\(writeCommand.recipient)",
            "write/reply-timeout": "\(writeCommand.replyTimeout)",
        ])

        do {
            // TODO: note that this impl does not handle "new node on same host/port" yet

            // register and manage reply callback ------------------------------
            if let replyCallback = writeCommand.replyCallback {
                let sequenceNr = writeCommand.message.sequenceNr

                let timeoutTask = context.eventLoop.scheduleTask(in: writeCommand.replyTimeout) {
                    self.log.trace("Timeout, no reply from [\(writeCommand.recipient)] after [\(writeCommand.replyTimeout.prettyDescription())]", metadata: [
                        "swim/request": "\(writeCommand.message)",
                        "timeout/nanos": "\(writeCommand.replyTimeout.nanoseconds)",
                    ])
                    if let callback = self.pendingReplyCallbacks.removeValue(forKey: writeCommand.message.sequenceNr) {
                        callback(.failure(
                            NIOSWIMTimeoutError(
                                timeout: writeCommand.replyTimeout,
                                message: "No reply to [\(writeCommand)] after \(writeCommand.replyTimeout.prettyDescription())" // TODO less loud
                            )
                        ))
                    }
                }

                self.pendingReplyCallbacks[sequenceNr] = { reply in
                    timeoutTask.cancel() // when we trigger the callback, we should also cancel the timeout task
                    replyCallback(reply) // successful reply received
                }
            }

            // serialize & send message ----------------------------------------
            let buffer = try self.serialize(message: writeCommand.message, using: context.channel.allocator)
            let envelope = AddressedEnvelope(remoteAddress: writeCommand.recipient, data: buffer)

            context.writeAndFlush(self.wrapOutboundOut(envelope), promise: promise)
        } catch {
            self.log.warning("Write failed: \(error)")
        }
    }

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let addressedEnvelope = self.unwrapInboundIn(data)

        // TODO: sanity check we are the recipient? UIDs...
        let remoteAddress = addressedEnvelope.remoteAddress

        self.log.warning("channel read", metadata: [
            "nio/remoteAddress": "\(remoteAddress)",
            "channel": "\(context.channel)",
        ])

        do {
            var bytes = addressedEnvelope.data
            var proto = ProtoSWIMMessage()
            try proto.merge(serializedData: bytes.readData(length: bytes.readableBytes)!) // FIXME: fix the !
            let message = try SWIM.Message(fromProto: proto)

            self.shell.receiveMessage(message: message)
        } catch {
            self.log.error("Read failed: \(error)", metadata: [
                "error": "\(error)",
            ])
        }
    }

    public func errorCaught(context: ChannelHandlerContext, error: Error) {
        self.log.error("Error caught: \(error)", metadata: [
            "nio/channel": "\(context.channel)",
            "swim/shell": "\(self.shell, orElse: "nil")",
            "error": "\(error)",
        ])
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

/// Used to a command to the channel pipeline to write the message,
/// and install a reply handler for the specific sequence number associated with the message (along with a timeout) when a callback is provided.
public struct WriteCommand {
    public let message: SWIM.Message
    public let recipient: SocketAddress

    public let replyTimeout: NIO.TimeAmount
    public let replyCallback: ((Result<SWIM.Message, Error>) -> Void)?

    public init(message: SWIM.Message, to recipient: Node, replyTimeout: TimeAmount, replyCallback: ((Result<SWIM.Message, Error>) -> Void)?) {
        self.message = message
        self.recipient = try! .init(ipAddress: recipient.host, port: recipient.port) // FIXME: try!
        self.replyTimeout = replyTimeout
        self.replyCallback = replyCallback
    }
}
