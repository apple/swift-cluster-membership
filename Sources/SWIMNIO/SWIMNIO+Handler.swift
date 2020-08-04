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
    var shell: SWIMNIOShell!

    // TODO: move callbacks into the shell?
    struct PendingResponseCallbackIdentifier: Hashable {
        let peerAddress: SocketAddress // TODO: UID as well...
        let sequenceNumber: SWIM.SequenceNumber
    }

    var pendingReplyCallbacks: [PendingResponseCallbackIdentifier: (Result<SWIM.Message, Error>) -> Void]

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
            node: node,
            settings: self.settings,
            channel: context.channel
        )

        self.log.trace("Channel active", metadata: [
            "nio/localAddress": "\(context.channel.localAddress)",
        ])
    }

    public func channelUnregistered(context: ChannelHandlerContext) {
        self.shell.receiveShutdown()
        context.fireChannelUnregistered()
    }

    public func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case let change as SWIM.MemberStatusChange:
            self.log.info("Membership changed: \(change.member), \(change.fromStatus) -> \(change.toStatus)")
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Write Messages

    public func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let writeCommand = self.unwrapOutboundIn(data)

        self.log.warning("write command: \(writeCommand.message.messageCaseDescription)", metadata: [
            "write/message": "\(writeCommand.message)",
            "write/recipient": "\(writeCommand.recipient)",
            "write/reply-timeout": "\(writeCommand.replyTimeout)",
        ])

        do {
            // TODO: note that this impl does not handle "new node on same host/port" yet

            // register and manage reply callback ------------------------------
            if let replyCallback = writeCommand.replyCallback {
                let sequenceNumber = writeCommand.message.sequenceNumber
                let callbackKey = PendingResponseCallbackIdentifier(peerAddress: writeCommand.recipient, sequenceNumber: writeCommand.message.sequenceNumber)

                let timeoutTask = context.eventLoop.scheduleTask(in: writeCommand.replyTimeout) {
                    if let callback = self.pendingReplyCallbacks.removeValue(forKey: callbackKey) {
                        callback(.failure(
                            SWIMNIOTimeoutError(
                                timeout: writeCommand.replyTimeout,
                                message: "No reply to [\(writeCommand.message.messageCaseDescription)] after \(writeCommand.replyTimeout.prettyDescription())"
                            )
                        ))
                    }
                }

                self.pendingReplyCallbacks[callbackKey] = { reply in
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

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Read Messages

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let addressedEnvelope: AddressedEnvelope<ByteBuffer> = self.unwrapInboundIn(data)
        let remoteAddress = addressedEnvelope.remoteAddress

        do {
            // deserialize ----------------------------------------
            let message = try self.deserialize(addressedEnvelope.data)

            self.log.trace("Read successful: \(message.messageCaseDescription)", metadata: [
                "remoteAddress": "\(remoteAddress)",
                "swim/message/type": "\(message.messageCaseDescription)",
                "swim/message": "\(message)",
            ])

            if message.isResponse {
                // if it's a reply, invoke the pending callback ------
                // TODO: move into the shell !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
                let callbackKey = PendingResponseCallbackIdentifier(peerAddress: remoteAddress, sequenceNumber: message.sequenceNumber)
                if let callback = self.pendingReplyCallbacks.removeValue(forKey: callbackKey) {
                    // TODO: UIDs of nodes...
                    self.log.warning("Received response, key: \(callbackKey); Invoking callback...", metadata: [
                        "pending/callbacks": Logger.MetadataValue.array(self.pendingReplyCallbacks.map { "\($0)" }),
                    ])
                    callback(.success(message))
                } else {
                    self.log.warning("No callback for \(callbackKey)... weird", metadata: [
                        "pending callbacks": Logger.MetadataValue.array(self.pendingReplyCallbacks.map { "\($0)" }),
                    ])
                }
            }
            // TODO: move into the shell ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
            else {
                // deliver to the shell ------------------------------
                self.shell.receiveMessage(message: message)
            }
        } catch {
            self.log.error("Read failed: \(error)", metadata: [
                "remoteAddress": "\(remoteAddress)",
                "message/bytes/count": "\(addressedEnvelope.data.readableBytes)",
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
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Serialization

extension SWIMProtocolHandler {
    private func deserialize(_ bytes: ByteBuffer) throws -> SWIM.Message {
        var bytes = bytes
        guard let data = bytes.readData(length: bytes.readableBytes) else {
            throw MissingDataError("No data to read")
        }

        var proto = ProtoSWIMMessage()
        try proto.merge(serializedData: data)
        return try SWIM.Message(fromProto: proto)
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

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Errors

struct MissingDataError: Error {
    let message: String
    init(_ message: String) {
        self.message = message
    }
}
