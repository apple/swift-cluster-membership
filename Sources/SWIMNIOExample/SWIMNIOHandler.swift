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
import Synchronization

/// `ChannelDuplexHandler` responsible for encoding/decoding SWIM messages to/from the `SWIMNIOShell`.
///
/// It is designed to work with `DatagramBootstrap`s, and the contained shell can send messages by writing `SWIMNIOSWIMNIOWriteCommand`
/// data into the channel which this handler converts into outbound `AddressedEnvelope<ByteBuffer>` elements.
public final class SWIMNIOHandler: ChannelDuplexHandler, Sendable {
  public typealias InboundIn = AddressedEnvelope<ByteBuffer>
  public typealias InboundOut = SWIM.MemberStatusChangedEvent<SWIM.NIOPeer>
  public typealias OutboundIn = SWIMNIOWriteCommand
  public typealias OutboundOut = AddressedEnvelope<ByteBuffer>

  let settings: SWIMNIO.Settings
  var log: Logger {
    self.settings.logger
  }

  // initialized in channelActive
  private let _shell: Mutex<SWIMNIOShell?> = .init(.none)
  var shell: SWIMNIOShell! {
    get { self._shell.withLock { $0 } }
    set { self._shell.withLock { $0 = newValue } }
  }

  private let _metrics: Mutex<SWIM.Metrics.ShellMetrics?> = .init(.none)
  var metrics: SWIM.Metrics.ShellMetrics? {
    get { self._metrics.withLock { $0 } }
    set { self._metrics.withLock { $0 = newValue } }
  }

  public init(settings: SWIMNIO.Settings) {
    self.settings = settings
  }

  public func channelActive(context: ChannelHandlerContext) {
    guard let hostIP = context.channel.localAddress!.ipAddress else {
      fatalError("SWIM requires a known host IP, but was nil! Channel: \(context.channel)")
    }
    guard let hostPort = context.channel.localAddress!.port else {
      fatalError("SWIM requires a known host IP, but was nil! Channel: \(context.channel)")
    }

    var settings = self.settings
    let node =
      self.settings.swim.node
      ?? Node(protocol: "udp", host: hostIP, port: hostPort, uid: .random(in: 0..<UInt64.max))
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

    self.log.trace(
      "Channel active",
      metadata: [
        "nio/localAddress": "\(context.channel.localAddress?.description ?? "unknown")"
      ])
  }

  public func channelUnregistered(context: ChannelHandlerContext) {
    self.shell.receiveShutdown()
    context.fireChannelUnregistered()
  }

  // ==== ------------------------------------------------------------------------------------------------------------
  // MARK: Write Messages

  public func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?)
  {
    let writeCommand = self.unwrapOutboundIn(data)

    let metadata: Logger.Metadata =
      switch writeCommand {
      case let .wait(reply, info):
        [
          "write/message": "\(info.message)",
          "write/recipient": "\(info.recipient)",
          "write/reply-timeout": "\(reply.timeout)",
        ]
      case .fireAndForget(let info):
        [
          "write/message": "\(info.message)",
          "write/recipient": "\(info.recipient)",
        ]
      }

    self.log.trace(
      "Write command: \(writeCommand.message.messageCaseDescription)",
      metadata: metadata
    )

    do {
      // TODO: note that this impl does not handle "new node on same host/port" yet

      self.shell.registerCallback(for: writeCommand)

      // serialize & send message ----------------------------------------
      let buffer = try self.serialize(
        message: writeCommand.message, using: context.channel.allocator)
      let envelope = AddressedEnvelope(remoteAddress: writeCommand.recipient, data: buffer)

      context.writeAndFlush(self.wrapOutboundOut(envelope), promise: promise)
    } catch {
      self.log.warning(
        "Write failed",
        metadata: [
          "error": "\(error)"
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

      self.log.trace(
        "Read successful: \(message.messageCaseDescription)",
        metadata: [
          "remoteAddress": "\(remoteAddress)",
          "swim/message/type": "\(message.messageCaseDescription)",
          "swim/message": "\(message)",
        ])
      // deliver to the shell ------------------------------
      self.shell.receiveMessage(
        message: message,
        from: remoteAddress
      )
    } catch {
      self.log.error(
        "Read failed: \(error)",
        metadata: [
          "remoteAddress": "\(remoteAddress)",
          "message/bytes/count": "\(addressedEnvelope.data.readableBytes)",
          "error": "\(error)",
        ])
    }
  }

  public func errorCaught(context: ChannelHandlerContext, error: Error) {
    self.log.error(
      "Error caught: \(error)",
      metadata: [
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

  private func serialize(message: SWIM.Message, using allocator: ByteBufferAllocator) throws
    -> ByteBuffer
  {
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
public enum SWIMNIOWriteCommand: Sendable {

  case wait(reply: Reply, info: Info)
  case fireAndForget(Info)

  public struct Info: Sendable {
    /// SWIM message to be written.
    public let message: SWIM.Message
    /// Address of recipient peer where the message should be written to.
    public let recipient: SocketAddress
  }

  public struct Reply: Sendable {
    /// If the `replyCallback` is set, what timeout should be set for a reply to come back from the peer.
    public let timeout: NIO.TimeAmount
    /// Callback to be invoked (calling into the SWIMNIOShell) when a reply to this message arrives.
    public let callback:
      @Sendable (Result<SWIM.PingResponse<SWIM.NIOPeer, SWIM.NIOPeer>, Error>) -> Void
  }

  var message: SWIM.Message {
    switch self {
    case .fireAndForget(let info): info.message
    case .wait(_, let info): info.message
    }
  }

  var recipient: SocketAddress {
    switch self {
    case .fireAndForget(let info): info.recipient
    case .wait(_, let info): info.recipient
    }
  }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Callback storage

// TODO: move callbacks into the shell?
struct PendingResponseCallbackIdentifier: Sendable, Hashable, CustomStringConvertible {
  let peerAddress: SocketAddress  // FIXME: UID as well...?
  let sequenceNumber: SWIM.SequenceNumber

  let storedAt: ContinuousClock.Instant = .now

  #if DEBUG
    let inResponseTo: SWIM.Message?
  #endif

  func hash(into hasher: inout Hasher) {
    hasher.combine(peerAddress)
    hasher.combine(sequenceNumber)
  }

  static func == (lhs: PendingResponseCallbackIdentifier, rhs: PendingResponseCallbackIdentifier)
    -> Bool
  {
    lhs.peerAddress == rhs.peerAddress && lhs.sequenceNumber == rhs.sequenceNumber
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

  func nanosecondsSinceCallbackStored(now: ContinuousClock.Instant = .now) -> Duration {
    storedAt.duration(to: now)
  }

  init(peerAddress: SocketAddress, sequenceNumber: SWIM.SequenceNumber, inResponseTo: SWIM.Message?)
  {
    self.peerAddress = peerAddress
    self.sequenceNumber = sequenceNumber
    self.inResponseTo = inResponseTo
  }

  init(peer: Node, sequenceNumber: SWIM.SequenceNumber, inResponseTo: SWIM.Message?) {
    self.peerAddress = try! .init(ipAddress: peer.host, port: peer.port)  // try!-safe since the host/port is always safe
    self.sequenceNumber = sequenceNumber
    self.inResponseTo = inResponseTo
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

// FIXME: Shouldn't be a case?
extension ChannelHandlerContext: @retroactive @unchecked Sendable {}
