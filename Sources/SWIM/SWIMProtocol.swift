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

/// This protocol defines all callbacks that a SWIM Shell (in other words, "runtime") must implement to properly drive
/// the underlying SWIM.Instance (which contains the complete logic of SWIM).
public protocol SWIMProtocol {
  associatedtype Peer: SWIMPeer
  associatedtype PingOrigin: SWIMPingOriginPeer
  associatedtype PingRequestOrigin: SWIMPingRequestOriginPeer

  typealias Instance = SWIM.Instance<Peer, PingOrigin, PingRequestOrigin>

  /// MUST be invoked periodically, in intervals of `self.swim.dynamicLHMProtocolInterval`.
  ///
  /// MUST NOT be scheduled using a "repeated" task/timer, as the interval is dynamic and may change as the algorithm proceeds.
  /// Implementations should schedule each next tick by handling the returned directive's `scheduleNextTick` case,
  /// which includes the appropriate delay to use for the next protocol tick.
  ///
  /// This is the heart of the protocol, as each tick corresponds to a "protocol period" in which:
  /// - suspect members are checked if they're overdue and should become `.unreachable` or `.dead`,
  /// - decisions are made to `.ping` a random peer for fault detection,
  /// - and some internal house keeping is performed.
  ///
  /// Note: This means that effectively all decisions are made in interval of protocol periods.
  /// It would be possible to have a secondary periodic or more ad-hoc interval to speed up
  /// some operations, however this is currently not implemented and the protocol follows the fairly
  /// standard mode of simply carrying payloads in periodic ping messages.
  ///
  /// - Returns: `SWIM.Instance.PeriodicPingTickDirective` which must be interpreted by a shell implementation
  mutating func onPeriodicPingTick() -> [Instance.PeriodicPingTickDirective]

  /// MUST be invoked whenever a `ping` message is received.
  ///
  /// A specific shell implementation must act on the returned directives.
  /// The order of interpreting the events should be as returned by the onPing invocation.
  ///
  /// - parameters:
  ///   - pingOrigin: the origin peer that issued this `ping`, it should be replied to (as instructed in the returned ping directive)
  ///   - payload: gossip information to be processed by this peer, resulting in potentially discovering new information about other members of the cluster
  ///   - sequenceNumber: sequence number of this ping, will be used to reply to the ping's origin using the same sequence number
  /// - Returns: `Instance.PingDirective` which must be interpreted by a shell implementation
  mutating func onPing(
    pingOrigin: PingOrigin,
    payload: SWIM.GossipPayload<Peer>?,
    sequenceNumber: SWIM.SequenceNumber
  ) -> [Instance.PingDirective]

  /// MUST be invoked when a `pingRequest` is received.
  ///
  /// The returned directives will instruct an implementation to perform probes of available peers on behalf of
  ///
  /// - parameters:
  ///   - target: target peer which this instance was asked to indirectly ping.
  ///   - pingRequestOrigin: the origin of this ping request; it should be notified with an .ack once we get a reply from the probed peer
  ///   - payload: gossip information to be processed by this peer, resulting in potentially discovering new information about other members of the cluster
  ///   - sequenceNumber: the sequenceNumber of the incoming `pingRequest`, used to reply with the appropriate sequence number once we get an `ack` from the target
  /// - Returns: `Instance.` which must be interpreted by a shell implementation
  mutating func onPingRequest(
    target: Peer,
    pingRequestOrigin: PingRequestOrigin,
    payload: SWIM.GossipPayload<Peer>?,
    sequenceNumber: SWIM.SequenceNumber
  ) -> [Instance.PingRequestDirective]

  /// MUST be invoked when a ping response (or timeout) occur for a specific ping.
  ///
  /// - parameters:
  ///   - response: the response (or timeout) related to this ping
  ///   - pingRequestOrigin: if this ping was issued on behalf of a `pingRequestOrigin`, that peer, otherwise `nil`
  ///   - pingRequestSequenceNumber: if this ping was issued on behalf of a `pingRequestOrigin`, then the sequence number of that `pingRequest`, otherwise `nil`
  /// - Returns: `Instance.PingResponseDirective` which must be interpreted by a shell implementation
  mutating func onPingResponse(
    response: SWIM.PingResponse<Peer, PingRequestOrigin>,
    pingRequestOrigin: PingRequestOrigin?,
    pingRequestSequenceNumber: SWIM.SequenceNumber?
  ) -> [Instance.PingResponseDirective]

  /// MUST be invoked exactly in one of the two following situations:
  /// - the *first successful response* from any number of `ping` messages that this peer has performed on behalf of a `pingRequestOrigin`,
  /// - just one single time with a `timeout` if *none* of the pings successfully returned an `ack`.
  ///
  /// - parameters:
  ///   - response: the response representing this ping's result (i.e. `ack` or `timeout`).
  ///   - pinged: the pinged peer that this response is from
  /// - Returns: `Instance.PingRequestResponseDirective` which must be interpreted by a shell implementation
  mutating func onPingRequestResponse(
    _ response: SWIM.PingResponse<Peer, PingRequestOrigin>,
    pinged: Peer
  ) -> [Instance.PingRequestResponseDirective]

  /// MUST be invoked whenever a response to a `pingRequest` (an ack, nack or lack response i.e. a timeout) happens.
  ///
  /// This function is adjusting Local Health and MUST be invoked on **every** received response to a pingRequest,
  /// in order for the local health adjusted timeouts to be calculated correctly.
  ///
  /// - parameters:
  ///   - response: the response representing
  ///   - pinged: the pinged peer that this response is from
  /// - Returns: `Instance.PingRequestResponseDirective` which must be interpreted by a shell implementation
  mutating func onEveryPingRequestResponse(
    _ response: SWIM.PingResponse<Peer, PingRequestOrigin>,
    pinged: Peer
  ) -> [Instance.PingRequestResponseDirective]

  /// Optional, only relevant when using `settings.unreachable` status mode (which is disabled by default).
  ///
  /// When `.unreachable` members are allowed, this function MUST be invoked to promote a node into `.dead` state.
  ///
  /// In other words, once a `MemberStatusChangedEvent` for an unreachable member has been emitted,
  /// a higher level system may take additional action and then determine when to actually confirm it dead.
  /// Systems can implement additional split-brain prevention mechanisms on those layers for example.
  ///
  /// Once a node is determined dead by such higher level system, it may invoke `swim.confirmDead(peer: theDefinitelyDeadPeer`,
  /// to mark the node as dead, with all of its consequences.
  ///
  /// - Parameter peer: the peer which should be confirmed dead.
  /// - Returns: `Instance.ConfirmDeadDirective` which must be interpreted by a shell implementation
  mutating func confirmDead(peer: Peer) -> Instance.ConfirmDeadDirective
}
