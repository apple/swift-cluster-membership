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
import struct Dispatch.DispatchTime
import Logging
import NIO
import NIOFoundationCompat
import SWIM

/// `ChannelDuplexHandler` responsible for encoding/decoding SWIM messages to/from the `SWIMNIOShell`.
///
/// It is designed to work with `DatagramBootstrap`s, and the contained shell can send messages by writing `SWIMNIOSWIMNIOWriteCommand`
/// data into the channel which this handler converts into outbound `AddressedEnvelope<ByteBuffer>` elements.
public final class SWIMNIOHandler: ChannelDuplexHandler {
    public typealias InboundIn = AddressedEnvelope<ByteBuffer>
    public typealias InboundOut = SWIM.MemberStatusChangedEvent<SWIM.NIOPeer>
    public typealias OutboundIn = SWIMNIOWriteCommand
    public typealias OutboundOut = AddressedEnvelope<ByteBuffer>

    let settings: SWIMNIO.Settings
    var log: Logger {
        self.settings.logger
    }

    // initialized in channelActive
    var shell: SWIMNIOShell!
    var metrics: SWIM.Metrics.ShellMetrics?

    var pendingReplyCallbacks: [PendingResponseCallbackIdentifier: (Result<SWIM.Message, Error>) -> Void]

    public init(settings: SWIMNIO.Settings) {
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

        var settings = self.settings
        let node = self.settings.swim.node ?? Node(protocol: "udp", host: hostIP, port: hostPort, uid: .random(in: 0 ..< UInt64.max))
        settings.swim.node = node
        self.shell = SWIMNIOShell(
            node: node,
            settings: settings,
            channel: context.channel,
            onMemberStatusChange: { change in
                context.eventLoop.execute {
                    let wrapped = self.wrapInboundOut(change)
                    context.fireChannelRead(wrapped)
                }
            }
        )
        self.metrics = self.shell.swim.metrics.shell

        self.log.trace("Channel active", metadata: [
            "nio/localAddress": "\(context.channel.localAddress?.description ?? "unknown")",
        ])
    }

    public func channelUnregistered(context: ChannelHandlerContext) {
        self.shell.receiveShutdown()
        context.fireChannelUnregistered()
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Write Messages

    public func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let writeCommand = self.unwrapOutboundIn(data)

        self.log.trace("Write command: \(writeCommand.message.messageCaseDescription)", metadata: [
            "write/message": "\(writeCommand.message)",
            "write/recipient": "\(writeCommand.recipient)",
            "write/reply-timeout": "\(writeCommand.replyTimeout)",
        ])

        do {
            // TODO: note that this impl does not handle "new node on same host/port" yet

            // register and manage reply callback ------------------------------
            if let replyCallback = writeCommand.replyCallback {
                let sequenceNumber = writeCommand.message.sequenceNumber
                #if DEBUG
                let callbackKey = PendingResponseCallbackIdentifier(peerAddress: writeCommand.recipient, sequenceNumber: sequenceNumber, inResponseTo: writeCommand.message)
                #else
                let callbackKey = PendingResponseCallbackIdentifier(peerAddress: writeCommand.recipient, sequenceNumber: sequenceNumber)
                #endif

                let timeoutTask = context.eventLoop.scheduleTask(in: writeCommand.replyTimeout) {
                    if let callback = self.pendingReplyCallbacks.removeValue(forKey: callbackKey) {
                        callback(.failure(
                            SWIMNIOTimeoutError(
                                timeout: writeCommand.replyTimeout,
                                message: "Timeout of [\(callbackKey)], no reply to [\(writeCommand.message.messageCaseDescription)] after \(writeCommand.replyTimeout.prettyDescription())"
                            )
                        ))
                    } // else, task fired already (should have been removed)
                }

                self.log.trace("Store callback: \(callbackKey)", metadata: [
                    "message": "\(writeCommand.message)",
                    "pending/callbacks": Logger.MetadataValue.array(self.pendingReplyCallbacks.map { "\($0)" }),
                ])
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
            self.log.warning("Write failed", metadata: [
                "error": "\(error)",
            ])
        }
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Read Messages

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let addressedEnvelope: AddressedEnvelope<ByteBuffer> = self.unwrapInboundIn(data)
        let remoteAddress = addressedEnvelope.remoteAddress

        do {
            // deserialize ----------------------------------------
            let message = try self.deserialize(addressedEnvelope.data, channel: context.channel)

            self.log.trace("Read successful: \(message.messageCaseDescription)", metadata: [
                "remoteAddress": "\(remoteAddress)",
                "swim/message/type": "\(message.messageCaseDescription)",
                "swim/message": "\(message)",
            ])

            if message.isResponse {
                // if it's a reply, invoke the pending callback ------
                // TODO: move into the shell: https://github.com/apple/swift-cluster-membership/issues/41
                #if DEBUG
                let callbackKey = PendingResponseCallbackIdentifier(peerAddress: remoteAddress, sequenceNumber: message.sequenceNumber, inResponseTo: nil)
                #else
                let callbackKey = PendingResponseCallbackIdentifier(peerAddress: remoteAddress, sequenceNumber: message.sequenceNumber)
                #endif

                if let index = self.pendingReplyCallbacks.index(forKey: callbackKey) {
                    let (storedKey, callback) = self.pendingReplyCallbacks.remove(at: index)
                    // TODO: UIDs of nodes matter
                    self.log.trace("Received response, key: \(callbackKey); Invoking callback...", metadata: [
                        "pending/callbacks": Logger.MetadataValue.array(self.pendingReplyCallbacks.map { "\($0)" }),
                    ])
                    self.metrics?.pingResponseTime.recordNanoseconds(storedKey.nanosecondsSinceCallbackStored().nanoseconds)
                    callback(.success(message))
                } else {
                    self.log.trace("No callback for \(callbackKey); It may have been removed due to a timeout already.", metadata: [
                        "pending callbacks": Logger.MetadataValue.array(self.pendingReplyCallbacks.map { "\($0)" }),
                    ])
                }
            } else {
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

extension SWIMNIOHandler {
    private func deserialize(_ bytes: ByteBuffer, channel: Channel) throws -> SWIM.Message {
        var bytes = bytes
        guard let data = bytes.readData(length: bytes.readableBytes) else {
            throw MissingDataError("No data to read")
        }

        self.metrics?.messageInboundCount.increment()
        self.metrics?.messageInboundBytes.record(data.count)

        let decoder = SWIMNIODefaultDecoder()
        decoder.userInfo[.channelUserInfoKey] = channel
        return try decoder.decode(SWIM.Message.self, from: data)
    }

    private func serialize(message: SWIM.Message, using allocator: ByteBufferAllocator) throws -> ByteBuffer {
        let encoder = SWIMNIODefaultEncoder()
        let data = try encoder.encode(message)

        self.metrics?.messageOutboundCount.increment()
        self.metrics?.messageOutboundBytes.record(data.count)

        let buffer = data.withUnsafeBytes { bytes -> ByteBuffer in
            var buffer = allocator.buffer(capacity: data.count)
            buffer.writeBytes(bytes)
            return buffer
        }
        return buffer
    }
}

/// Used to a command to the channel pipeline to write the message,
/// and install a reply handler for the specific sequence number associated with the message (along with a timeout)
/// when a callback is provided.
public struct SWIMNIOWriteCommand {
    /// SWIM message to be written.
    public let message: SWIM.Message
    /// Address of recipient peer where the message should be written to.
    public let recipient: SocketAddress

    /// If the `replyCallback` is set, what timeout should be set for a reply to come back from the peer.
    public let replyTimeout: NIO.TimeAmount
    /// Callback to be invoked (calling into the SWIMNIOShell) when a reply to this message arrives.
    public let replyCallback: ((Result<SWIM.Message, Error>) -> Void)?

    /// Create a write command.
    public init(message: SWIM.Message, to recipient: Node, replyTimeout: TimeAmount, replyCallback: ((Result<SWIM.Message, Error>) -> Void)?) {
        self.message = message
        self.recipient = try! .init(ipAddress: recipient.host, port: recipient.port) // try!-safe since the host/port is always safe
        self.replyTimeout = replyTimeout
        self.replyCallback = replyCallback
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Callback storage

// TODO: move callbacks into the shell?
struct PendingResponseCallbackIdentifier: Hashable, CustomStringConvertible {
    let peerAddress: SocketAddress // FIXME: UID as well...?
    let sequenceNumber: SWIM.SequenceNumber

    let storedAt: DispatchTime = .now()

    #if DEBUG
    let inResponseTo: SWIM.Message?
    #endif

    func hash(into hasher: inout Hasher) {
        hasher.combine(peerAddress)
        hasher.combine(sequenceNumber)
    }

    static func == (lhs: PendingResponseCallbackIdentifier, rhs: PendingResponseCallbackIdentifier) -> Bool {
        lhs.peerAddress == rhs.peerAddress &&
            lhs.sequenceNumber == rhs.sequenceNumber
    }

    var description: String {
        """
        PendingResponseCallbackIdentifier(\
        peerAddress: \(peerAddress), \
        sequenceNumber: \(sequenceNumber), \
        storedAt: \(self.storedAt) (\(nanosecondsSinceCallbackStored()) ago)\
        )
        """
    }

    func nanosecondsSinceCallbackStored(now: DispatchTime = .now()) -> Duration {
        Duration.nanoseconds(Int(now.uptimeNanoseconds - storedAt.uptimeNanoseconds))
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
