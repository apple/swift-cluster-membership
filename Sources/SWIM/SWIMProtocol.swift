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
#if os(macOS) || os(iOS) || os(watchOS) || os(tvOS)
import Darwin
#else
import Glibc
#endif
import struct Dispatch.DispatchTime
import Logging

/// ## Scalable Weakly-consistent Infection-style Process Group Membership Protocol
///
/// > As you swim lazily through the milieu, <br/>
/// > The secrets of the world will infect you.
///
/// Implementation of the SWIM protocol in abstract terms, not dependent on any specific runtime.
/// The actual implementation resides in `SWIM.Instance`.
///
/// ### Terminology
/// This implementation follows the original terminology mostly directly, with the notable exception of the original
/// wording of "confirm" being rather represented as `SWIM.Status.dead`, as we found the "confirm" wording to be
/// confusing in practice.
///
/// ### Extensions & Modifications
///
/// This implementation has a few notable extensions and modifications implemented, some documented already in the initial
/// SWIM paper, some in the Lifeguard extensions paper and some being simple adjustments we found practical in our environments.
///
/// - The "random peer selection" is not completely ad-hoc random, but follows a _stable order_, randomized on peer insertion.
///   - Unlike the completely random selection in the original paper. This has the benefit of consistently going "around"
///     all peers participating in the cluster, enabling a more efficient spread of membership information among peers,
///     by allowing us to avoid continuously (yet randomly) selecting the same few peers.
///   - This optimization is described in the original SWIM paper, and followed by some implementations.
///
/// - Introduction of an `.unreachable` status, that is ordered after `.suspect` and before `.dead`.
///   - This is because the decision to move an unreachable peer to .dead status is a large and important decision,
///     in which user code may want to participate, e.g. by attempting "shoot the other peer in the head" or other patterns,
///     before triggering the `.dead` status (which usually implies a complete removal of information of that peer existence from the cluster),
///     after which no further communication with given peer will ever be possible anymore.
///   - The `.unreachable` status is optional and _disabled_ by default.
///   - Other SWIM implementations handle this problem by _storing_ dead members for a period of time after declaring them dead,
///     also deviating from the original paper; so we conclude that this use case is quite common and allow addressing it in various ways.
///
/// - Preservation of `.unreachable` information
///   - The original paper does not keep in memory information about dead peers,
///     it only gossips the information that a member is now dead, but does not keep tombstones for later reference.
///
/// Implementations of extensions documented in the Lifeguard paper (linked below):
///
/// - Local Health Aware Probe - which replaces the static timeouts in probing with a dynamic one, taking into account
///   recent communication failures of our member with others.
/// - Local Health Aware Suspicion - which improves the way `.suspect` states and their timeouts are handled,
///   effectively relying on more information about unreachability. See: `suspicionTimeout`.
/// - Buddy System - enables members to directly and immediately notify suspect peers about them being suspected,
///   such that they have more time and a chance to refute these suspicions more quickly, rather than relying on completely
///   random gossip for that suspicion information to reach such suspect peer.
///
/// SWIM serves as a low-level distributed failure detector mechanism.
/// It also maintains its own membership in order to monitor and select peers to ping with periodic health checks,
/// however this membership is not directly the same as the high-level membership exposed by the `Cluster`.
///
/// ### SWIM Membership
/// SWIM provides a weakly consistent view on the process group membership.
/// Membership in this context means that we have some knowledge about the node, that was acquired by either
/// communicating with the peer directly, for example when initially connecting to the cluster,
/// or because some other peer shared information about it with us.
/// To avoid moving a peer "back" into alive or suspect state because of older statuses that get replicated,
/// we need to be able to put them into temporal order. For this reason each peer has an incarnation number assigned to it.
///
/// This number is monotonically increasing and can only be incremented by the respective peer itself and only if it is
/// suspected by another peer in its current incarnation.
///
/// The ordering of statuses is as follows:
///
///     alive(N) < suspect(N) < alive(N+1) < suspect(N+1) < dead
///
/// A member that has been declared dead can *never* return from that status and has to be restarted to join the cluster.
/// Note that such "restarted node" from SWIM's perspective is simply a new node which happens to occupy the same host/port,
/// as nodes are identified by their unique identifiers (`ClusterMembership.Node.uid`).
///
/// The information about dead nodes will be kept for a configurable amount of time, after which it will be removed to
/// prevent the state on each node from growing too big. The timeout value should be chosen to be big enough to prevent
/// faulty nodes from re-joining the cluster and is usually in the order of a few days.
///
/// ### SWIM Gossip
///
/// SWIM uses an infection style gossip mechanism to replicate state across the cluster.
/// The gossip payload contains information about other node’s observed status, and will be disseminated throughout the
/// cluster by piggybacking onto periodic health check messages, i.e. whenever a node is sending a ping, a ping request,
/// or is responding with an acknowledgement, it will include the latest gossip with that message as well. When a node
/// receives gossip, it has to apply the statuses to its local state according to the ordering stated above. If a node
/// receives gossip about itself, it has to react accordingly.
///
/// If it is suspected by another peer in its current incarnation, it has to increment its incarnation in response.
/// If it has been marked as dead, it SHOULD shut itself down (i.e. terminate the entire node / service), to avoid "zombie"
/// nodes staying around even though they are already ejected from the cluster.
///
/// ### SWIM Protocol Logic Implementation
///
/// See `SWIM.Instance` for a detailed discussion on the implementation.
///
/// ### Further Reading
///
/// - [SWIM: Scalable Weakly-consistent Infection-style Process Group Membership Protocol](https://www.cs.cornell.edu/projects/Quicksilver/public_pdfs/SWIM.pdf)
/// - [Lifeguard: Local Health Awareness for More Accurate Failure Detection](https://arxiv.org/abs/1707.00788)
public enum SWIM {}

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
        payload: SWIM.GossipPayload<Peer>,
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
        payload: SWIM.GossipPayload<Peer>,
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
    mutating func onPingRequestResponse(_ response: SWIM.PingResponse<Peer, PingRequestOrigin>, pinged: Peer) -> [Instance.PingRequestResponseDirective]

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
