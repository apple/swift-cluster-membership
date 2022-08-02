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

extension SWIM {
    /// The `SWIM.Instance` encapsulates the complete algorithm implementation of the `SWIM` protocol.
    ///
    /// **Please refer to `SWIM` for an in-depth discussion of the algorithm and extensions implemented in this package.**
    ///
    /// - SeeAlso: `SWIM` for a complete and in depth discussion of the protocol.
    public struct Instance<
        Peer: SWIMPeer,
        PingOrigin: SWIMPingOriginPeer,
        PingRequestOrigin: SWIMPingRequestOriginPeer
    >: SWIMProtocol {
        /// The settings currently in use by this instance.
        public let settings: SWIM.Settings

        /// Struct containing all metrics a SWIM Instance (and implementation Shell) should emit.
        public let metrics: SWIM.Metrics

        /// Node which this SWIM.Instance is representing in the cluster.
        public var swimNode: ClusterMembership.Node {
            self.peer.node
        }

        // Convenience overload for internal use so we don't have to repeat "swim" all the time.
        internal var node: ClusterMembership.Node {
            self.swimNode
        }

        private var log: Logger {
            self.settings.logger
        }

        /// The `SWIM.Member` representing this instance, also referred to as "myself".
        public var member: SWIM.Member<Peer> {
            if let storedMyself = self.member(forNode: self.swimNode),
                !storedMyself.status.isAlive {
                return storedMyself // it is something special, like .dead
            } else {
                // return the always up to date "our view" on ourselves
                return SWIM.Member(peer: self.peer, status: .alive(incarnation: self.incarnation), protocolPeriod: self.protocolPeriod)
            }
        }

        // We store the owning SWIMShell peer in order avoid adding it to the `membersToPing` list
        private let peer: Peer

        /// Main members storage, map to values to obtain current members.
        internal var _members: [ClusterMembership.Node: SWIM.Member<Peer>] {
            didSet {
                self.metrics.updateMembership(self.members)
            }
        }

        /// List of members maintained in random yet stable order, see `addMember` for details.
        internal var membersToPing: [SWIM.Member<Peer>]
        /// Constantly mutated by `nextMemberToPing` in an effort to keep the order in which we ping nodes evenly distributed.
        private var _membersToPingIndex: Int = 0
        private var membersToPingIndex: Int {
            self._membersToPingIndex
        }

        /// Tombstones are needed to avoid accidentally re-adding a member that we confirmed as dead already.
        internal var removedDeadMemberTombstones: Set<MemberTombstone> = [] {
            didSet {
                self.metrics.removedDeadMemberTombstones.record(self.removedDeadMemberTombstones.count)
            }
        }

        private var _sequenceNumber: SWIM.SequenceNumber = 0
        /// Sequence numbers are used to identify messages and pair them up into request/replies.
        /// - SeeAlso: `SWIM.SequenceNumber`
        public mutating func nextSequenceNumber() -> SWIM.SequenceNumber {
            // TODO: can we make it internal? it does not really hurt having public
            // TODO: sequence numbers per-target node? https://github.com/apple/swift-cluster-membership/issues/39
            self._sequenceNumber += 1
            return self._sequenceNumber
        }

        /// Lifeguard IV.A. Local Health Multiplier (LHM)
        /// > These different sources of feedback are combined in a Local Health Multiplier (LHM).
        /// > LHM is a saturating counter, with a max value S and min value zero, meaning it will not
        /// > increase above S or decrease below zero.
        ///
        /// The local health multiplier (LHM for short) is designed to relax the `probeInterval` and `pingTimeout`.
        ///
        /// The value MUST be >= 0.
        ///
        /// - SeeAlso: `SWIM.Instance.LHModifierEvent` for details how and when the LHM is adjusted.
        public var localHealthMultiplier = 0 {
            didSet {
                assert(self.localHealthMultiplier >= 0, "localHealthMultiplier MUST NOT be < 0, but was: \(self.localHealthMultiplier)")
                self.metrics.localHealthMultiplier.record(self.localHealthMultiplier)
            }
        }

        /// Dynamically adjusted probing interval.
        ///
        /// Usually this interval will be yielded with a directive at appropriate spots, so it should not be
        /// necessary to invoke it manually.
        ///
        /// - SeeAlso: `localHealthMultiplier` for more detailed documentation.
        /// - SeeAlso: Lifeguard IV.A. Local Health Multiplier (LHM)
        var dynamicLHMProtocolInterval: Duration {
            .nanoseconds(Int(self.settings.probeInterval.nanoseconds * Int64(1 + self.localHealthMultiplier)))
        }

        /// Dynamically adjusted (based on Local Health) timeout to be used when sending `ping` messages.
        ///
        /// Usually this interval will be yielded with a directive at appropriate spots, so it should not be
        /// necessary to invoke it manually.
        ///
        /// - SeeAlso: `localHealthMultiplier` for more detailed documentation.
        /// - SeeAlso: Lifeguard IV.A. Local Health Multiplier (LHM)
        var dynamicLHMPingTimeout: Duration {
            .nanoseconds(Int(self.settings.pingTimeout.nanoseconds * Int64(1 + self.localHealthMultiplier)))
        }

        /// The incarnation number is used to get a sense of ordering of events, so if an `.alive` or `.suspect`
        /// state with a lower incarnation than the one currently known by a node is received, it can be dropped
        /// as outdated and we don't accidentally override state with older events. The incarnation can only
        /// be incremented by the respective node itself and will happen if that node receives a `.suspect` for
        /// itself, to which it will respond with an `.alive` with the incremented incarnation.
        var incarnation: SWIM.Incarnation {
            self._incarnation
        }

        private var _incarnation: SWIM.Incarnation = 0 {
            didSet {
                self.metrics.incarnation.record(self._incarnation)
            }
        }

        private mutating func nextIncarnation() {
            self._incarnation += 1
        }

        /// Creates a new SWIM algorithm instance.
        public init(settings: SWIM.Settings, myself: Peer) {
            self.settings = settings
            self.peer = myself
            self._members = [:]
            self.membersToPing = []
            self.metrics = SWIM.Metrics(settings: settings)
            _ = self.addMember(myself, status: .alive(incarnation: 0))

            self.metrics.incarnation.record(self.incarnation)
            self.metrics.localHealthMultiplier.record(self.localHealthMultiplier)
            self.metrics.updateMembership(self.members)
        }

        func makeSuspicion(incarnation: SWIM.Incarnation) -> SWIM.Status {
            .suspect(incarnation: incarnation, suspectedBy: [self.node])
        }

        func mergeSuspicions(suspectedBy: Set<ClusterMembership.Node>, previouslySuspectedBy: Set<ClusterMembership.Node>) -> Set<ClusterMembership.Node> {
            var newSuspectedBy = previouslySuspectedBy
            for suspectedBy in suspectedBy.sorted() where newSuspectedBy.count < self.settings.lifeguard.maxIndependentSuspicions {
                newSuspectedBy.update(with: suspectedBy)
            }
            return newSuspectedBy
        }

        /// Adjust the Local Health-aware Multiplier based on the event causing it.
        ///
        /// - Parameter event: event which causes the LHM adjustment.
        public mutating func adjustLHMultiplier(_ event: LHModifierEvent) {
            defer {
                self.settings.logger.trace("Adjusted LHM multiplier", metadata: [
                    "swim/lhm/event": "\(event)",
                    "swim/lhm": "\(self.localHealthMultiplier)",
                ])
            }

            self.localHealthMultiplier =
                min(
                    max(0, self.localHealthMultiplier + event.lhmAdjustment),
                    self.settings.lifeguard.maxLocalHealthMultiplier
                )
        }

        // The protocol period represents the number of times we have pinged a random member
        // of the cluster. At the end of every ping cycle, the number will be incremented.
        // Suspicion timeouts are based on the protocol period, i.e. if a probe did not
        // reply within any of the `suspicionTimeoutPeriodsMax` rounds, it would be marked as `.suspect`.
        private var _protocolPeriod: UInt64 = 0

        /// In order to speed up the spreading of "fresh" rumors, we order gossips in their "number of times gossiped",
        /// and thus are able to easily pick the least spread rumor and pick it for the next gossip round.
        ///
        /// This is tremendously important in order to spread information about e.g. newly added members to others,
        /// before members which are aware of them could have a chance to all terminate, leaving the rest of the cluster
        /// unaware about those new members. For disseminating suspicions this is less urgent, however also serves as an
        /// useful optimization.
        ///
        /// - SeeAlso: SWIM 4.1. Infection-Style Dissemination Component
        private var _messagesToGossip: Heap<SWIM.Gossip<Peer>> = Heap(
            comparator: {
                $0.numberOfTimesGossiped < $1.numberOfTimesGossiped
            }
        )

        /// Note that peers without UID (in their `Node`) will NOT be added to the membership.
        ///
        /// This is because a cluster member must be a _specific_ peer instance, and not some arbitrary "some peer on that host/port",
        /// which a Node without UID represents. The only reason we allow for peers and nodes without UID, is to simplify making
        /// initial contact with a node - i.e. one can construct a peer to "there should be a peer on this host/port" to send an initial ping,
        /// however in reply a peer in gossip must ALWAYS include it's unique identifier in the node - such that we know it from
        /// any new instance of a process on the same host/port pair.
        internal mutating func addMember(_ peer: Peer, status: SWIM.Status) -> [AddMemberDirective] {
            var directives: [AddMemberDirective] = []

            // Guard 1) protect against adding already known dead members
            if self.hasTombstone(peer.node) {
                // We saw this member already and even confirmed it dead, it shall never be added again
                self.log.debug("Attempt to re-add already confirmed dead peer \(peer), ignoring it.")
                directives.append(.memberAlreadyKnownDead(Member(peer: peer, status: .dead, protocolPeriod: 0)))
                return directives
            }

            // Guard 2) protect against adding non UID members
            guard peer.node.uid != nil else {
                self.log.warning("Ignoring attempt to add peer representing node without UID: \(peer)")
                return directives
            }

            let maybeExistingMember = self.member(for: peer)
            if let existingMember = maybeExistingMember, existingMember.status.supersedes(status) {
                // we already have a newer state for this member
                directives.append(.newerMemberAlreadyPresent(existingMember))
                return directives
            }

            /// if we're adding a node, it may be a reason to declare the previous "incarnation" as dead
            // TODO: could solve by another dictionary without the UIDs?
            if let withoutUIDMatchMember = self._members.first(where: { $0.value.node.withoutUID == peer.node.withoutUID })?.value,
                peer.node.uid != nil, // the incoming node has UID, so it definitely is a real peer
                peer.node.uid != withoutUIDMatchMember.node.uid { // the peers don't agree on UID, it must be a new node on same host/port
                switch self.confirmDead(peer: withoutUIDMatchMember.peer) {
                case .ignored:
                    () // should not happen?
                case .applied(let change):
                    directives.append(.previousHostPortMemberConfirmedDead(change))
                }
            }

            // just in case we had a peer added manually, and thus we did not know its uuid, let us remove it
            // maybe we replaced a mismatching UID node already, but let's sanity check and remove also if we stored any "without UID" node
            if let removed = self._members.removeValue(forKey: self.node.withoutUID) {
                switch self.confirmDead(peer: removed.peer) {
                case .ignored:
                    () // should not happen?
                case .applied(let change):
                    directives.append(.previousHostPortMemberConfirmedDead(change))
                }
            }

            let member = SWIM.Member(peer: peer, status: status, protocolPeriod: self.protocolPeriod)
            self._members[member.node] = member

            if self.notMyself(member), !member.isDead {
                // We know this is a new member.
                //
                // Newly added members are inserted at a random spot in the list of members
                // to ping, to have a better distribution of messages to this node from all
                // other nodes. If for example all nodes would add it to the end of the list,
                // it would take a longer time until it would be pinged for the first time
                // and also likely receive multiple pings within a very short time frame.
                let insertIndex = Int.random(in: self.membersToPing.startIndex ... self.membersToPing.endIndex)
                self.membersToPing.insert(member, at: insertIndex)
                if insertIndex <= self.membersToPingIndex {
                    // If we inserted the new member before the current `membersToPingIndex`,
                    // we need to advance the index to avoid pinging the same member multiple
                    // times in a row. This is especially critical when inserting a larger
                    // number of members, e.g. when the cluster is just being formed, or
                    // on a rolling restart.
                    self.advanceMembersToPingIndex()
                }
            }

            // upon each membership change we reset the gossip counters
            // such that nodes have a chance to be notified about others,
            // even if a node joined an otherwise quiescent cluster.
            self.resetGossipPayloads(member: member)

            directives.append(.added(member))

            return directives
        }

        enum AddMemberDirective {
            /// Informs an implementation that a new member was added and now has the following state.
            /// An implementation should react to this by emitting a cluster membership change event.
            case added(SWIM.Member<Peer>)
            /// By adding a node with a new UID on the same host/port, we may actually invalidate any previous member that
            /// existed on this host/port part. If this is the case, we confirm the "previous" member on the same host/port
            /// pair as dead immediately.
            case previousHostPortMemberConfirmedDead(SWIM.MemberStatusChangedEvent<Peer>)
            /// We already have information about this exact `Member`, and our information is more recent (higher incarnation number).
            /// The incoming information was discarded and the returned here member is the most up to date information we have.
            case newerMemberAlreadyPresent(SWIM.Member<Peer>)
            /// Member already was part of the cluster, became dead and we removed it.
            /// It shall never be part of the cluster again.
            ///
            /// This is only enforced by tombstones which are kept in the system for a period of time,
            /// in the hope that all other nodes stop gossiping about this known dead member until then as well.
            case memberAlreadyKnownDead(SWIM.Member<Peer>)
        }

        /// Implements the round-robin yet shuffled member to probe selection as proposed in the SWIM paper.
        ///
        /// This mechanism should reduce the time until state is spread across the whole cluster,
        /// by guaranteeing that each node will be gossiped to within N cycles (where N is the cluster size).
        ///
        /// - Note:
        ///   SWIM 4.3: [...] The failure detection protocol at member works by maintaining a list (intuitively, an array) of the known
        ///   elements of the current membership list, and select-ing ping targets not randomly from this list,
        ///   but in a round-robin fashion. Instead, a newly joining member is inserted in the membership list at
        ///   a position that is chosen uniformly at random. On completing a traversal of the entire list,
        ///   rearranges the membership list to a random reordering.
        mutating func nextPeerToPing() -> Peer? {
            if self.membersToPing.isEmpty {
                return nil
            }

            defer {
                self.advanceMembersToPingIndex()
            }
            return self.membersToPing[self.membersToPingIndex].peer
        }

        /// Selects `settings.indirectProbeCount` members to send a `ping-req` to.
        func membersToPingRequest(target: SWIMAddressablePeer) -> ArraySlice<SWIM.Member<Peer>> {
            func notTarget(_ peer: SWIMAddressablePeer) -> Bool {
                peer.node != target.node
            }

            func isReachable(_ status: SWIM.Status) -> Bool {
                status.isAlive || status.isSuspect
            }

            let candidates = self._members
                .values
                .filter {
                    notTarget($0.peer) && notMyself($0.peer) && isReachable($0.status)
                }
                .shuffled()

            return candidates.prefix(self.settings.indirectProbeCount)
        }

        /// Mark a specific peer/member with the new status.
        mutating func mark(_ peer: Peer, as status: SWIM.Status) -> MarkedDirective {
            let previousStatusOption = self.status(of: peer)

            var status = status
            var protocolPeriod = self.protocolPeriod
            var suspicionStartedAt: DispatchTime?

            if case .suspect(let incomingIncarnation, let incomingSuspectedBy) = status,
                case .suspect(let previousIncarnation, let previousSuspectedBy)? = previousStatusOption,
                let member = self.member(for: peer),
                incomingIncarnation == previousIncarnation {
                let suspicions = self.mergeSuspicions(suspectedBy: incomingSuspectedBy, previouslySuspectedBy: previousSuspectedBy)
                status = .suspect(incarnation: incomingIncarnation, suspectedBy: suspicions)
                // we should keep old protocol period when member is already a suspect
                protocolPeriod = member.protocolPeriod
                suspicionStartedAt = member.localSuspicionStartedAt
            } else if case .suspect = status {
                suspicionStartedAt = self.now()
            } else if case .unreachable = status,
                case SWIM.Settings.UnreachabilitySettings.disabled = self.settings.unreachability {
                self.log.warning("Attempted to mark \(peer.node) as `.unreachable`, but unreachability is disabled! Promoting to `.dead`!")
                status = .dead
            }

            if let previousStatus = previousStatusOption, previousStatus.supersedes(status) {
                // we already have a newer status for this member
                return .ignoredDueToOlderStatus(currentStatus: previousStatus)
            }

            let member = SWIM.Member(peer: peer, status: status, protocolPeriod: protocolPeriod, suspicionStartedAt: suspicionStartedAt)
            self._members[peer.node] = member

            if status.isDead {
                if let _ = self._members.removeValue(forKey: peer.node) {
                    self.metrics.membersTotalDead.increment()
                }
                self.removeFromMembersToPing(member)
                if let uid = member.node.uid {
                    let deadline = self.protocolPeriod + self.settings.tombstoneTimeToLiveInTicks
                    let tombstone = MemberTombstone(uid: uid, deadlineProtocolPeriod: deadline)
                    self.removedDeadMemberTombstones.insert(tombstone)
                }
            }

            self.resetGossipPayloads(member: member)

            return .applied(previousStatus: previousStatusOption, member: member)
        }

        enum MarkedDirective: Equatable {
            /// The status that was meant to be set is "old" and was ignored.
            /// We already have newer information about this peer (`currentStatus`).
            case ignoredDueToOlderStatus(currentStatus: SWIM.Status)
            case applied(previousStatus: SWIM.Status?, member: SWIM.Member<Peer>)
        }

        private mutating func resetGossipPayloads(member: SWIM.Member<Peer>) {
            // seems we gained a new member, and we need to reset gossip counts in order to ensure it also receive information about all nodes
            // TODO: this would be a good place to trigger a full state sync, to speed up convergence; see https://github.com/apple/swift-cluster-membership/issues/37
            self.members.forEach { self.addToGossip(member: $0) }
        }

        mutating func incrementProtocolPeriod() {
            self._protocolPeriod += 1
        }

        mutating func advanceMembersToPingIndex() {
            self._membersToPingIndex = (self._membersToPingIndex + 1) % self.membersToPing.count
        }

        mutating func removeFromMembersToPing(_ member: SWIM.Member<Peer>) {
            if let index = self.membersToPing.firstIndex(where: { $0.peer.node == member.peer.node }) {
                self.membersToPing.remove(at: index)
                if index < self.membersToPingIndex {
                    self._membersToPingIndex -= 1
                }

                if self.membersToPingIndex >= self.membersToPing.count {
                    self._membersToPingIndex = self.membersToPing.startIndex
                }
            }
        }

        /// Current SWIM protocol period (i.e. which round of gossip the instance is in).
        public var protocolPeriod: UInt64 {
            self._protocolPeriod
        }

        /// Debug only. Actual suspicion timeout depends on number of suspicions and calculated in `suspicionTimeout`
        /// This will only show current estimate of how many intervals should pass before suspicion is reached. May change when more data is coming
        var timeoutSuspectsBeforePeriodMax: Int64 {
            self.settings.lifeguard.suspicionTimeoutMax.nanoseconds / self.dynamicLHMProtocolInterval.nanoseconds + 1
        }

        /// Debug only. Actual suspicion timeout depends on number of suspicions and calculated in `suspicionTimeout`
        /// This will only show current estimate of how many intervals should pass before suspicion is reached. May change when more data is coming
        var timeoutSuspectsBeforePeriodMin: Int64 {
            self.settings.lifeguard.suspicionTimeoutMin.nanoseconds / self.dynamicLHMProtocolInterval.nanoseconds + 1
        }

        /// Local Health Aware Suspicion timeout calculation, as defined Lifeguard IV.B.
        ///
        /// Suspicion timeout is logarithmically decaying from `suspicionTimeoutPeriodsMax` to `suspicionTimeoutPeriodsMin`
        /// depending on a number of suspicion confirmations.
        ///
        /// Suspicion timeout adjusted according to number of known independent suspicions of given member.
        ///
        /// See: Lifeguard IV-B: Local Health Aware Suspicion
        ///
        /// The timeout for a given suspicion is calculated as follows:
        ///
        /// ```
        ///                                             log(C + 1) 􏰁
        /// SuspicionTimeout =􏰀 max(Min, Max − (Max−Min) ----------)
        ///                                             log(K + 1)
        /// ```
        ///
        /// where:
        /// - `Min` and `Max` are the minimum and maximum Suspicion timeout.
        ///   See Section `V-C` for discussion of their configuration.
        /// - `K` is the number of independent suspicions required to be received before setting the suspicion timeout to `Min`.
        ///   We default `K` to `3`.
        /// - `C` is the number of independent suspicions about that member received since the local suspicion was raised.
        public func suspicionTimeout(suspectedByCount: Int) -> Duration {
            let minTimeout = self.settings.lifeguard.suspicionTimeoutMin.nanoseconds
            let maxTimeout = self.settings.lifeguard.suspicionTimeoutMax.nanoseconds

            return .nanoseconds(
                Int(
                    max(
                        minTimeout,
                        maxTimeout - Int64(round(Double(maxTimeout - minTimeout) * (log2(Double(suspectedByCount + 1)) / log2(Double(self.settings.lifeguard.maxIndependentSuspicions + 1)))))
                    )
                )
            )
        }

        /// Checks if a deadline is expired (relating to current time).
        ///
        /// - Parameter deadline: deadline we want to check if it's expired
        /// - Returns: true if the `now()` time is "past" the deadline
        public func isExpired(deadline: DispatchTime) -> Bool {
            deadline < self.now()
        }

        /// Returns the current point in time on this machine.
        /// - Note: `DispatchTime` is simply a number of nanoseconds since boot on this machine, and thus is not comparable across machines.
        ///   We use it on purpose, as we do not intend to share our local time observations with any other peers.
        private func now() -> DispatchTime {
            self.settings.timeSourceNow()
        }

        /// Create a gossip payload (i.e. a set of `SWIM.Gossip` messages) that should be gossiped with failure detector
        /// messages, or using some other medium.
        ///
        /// - Parameter target: Allows passing the target peer this gossip will be sent to.
        ///     If gossiping to a specific peer, and given peer is suspect, we will always prioritize
        ///     letting it know that it is being suspected, such that it can refute the suspicion as soon as possible,
        ///     if if still is alive.
        /// - Returns: The gossip payload to be gossiped.
        public mutating func makeGossipPayload(to target: SWIMAddressablePeer?) -> SWIM.GossipPayload<Peer> {
            var membersToGossipAbout: [SWIM.Member<Peer>] = []
            // Lifeguard IV. Buddy System
            // Always send to a suspect its suspicion.
            // The reason for that to ensure the suspect will be notified it is being suspected,
            // even if the suspicion has already been disseminated "enough times".
            let targetIsSuspect: Bool
            if let target = target,
                let member = self.member(forNode: target.node),
                member.isSuspect {
                // the member is suspect, and we must inform it about this, thus including in gossip payload:
                membersToGossipAbout.append(member)
                targetIsSuspect = true
            } else {
                targetIsSuspect = false
            }

            guard self._messagesToGossip.count > 0 else {
                if membersToGossipAbout.isEmpty {
                    // if we have no pending gossips to share, at least inform the member about our state.
                    return .membership([self.member])
                } else {
                    return .membership(membersToGossipAbout)
                }
            }

            // In order to avoid duplicates within a single gossip payload, we first collect all messages we need to
            // gossip out and only then re-insert them into `messagesToGossip`. Otherwise, we may end up selecting the
            // same message multiple times, if e.g. the total number of messages is smaller than the maximum gossip
            // size, or for newer messages that have a lower `numberOfTimesGossiped` counter than the other messages.
            var gossipRoundMessages: [SWIM.Gossip<Peer>] = []
            gossipRoundMessages.reserveCapacity(min(self.settings.gossip.maxNumberOfMessagesPerGossip, self._messagesToGossip.count))
            while gossipRoundMessages.count < self.settings.gossip.maxNumberOfMessagesPerGossip,
                let gossip = self._messagesToGossip.removeRoot() {
                gossipRoundMessages.append(gossip)
            }

            membersToGossipAbout.reserveCapacity(gossipRoundMessages.count)

            for var gossip in gossipRoundMessages {
                if targetIsSuspect, target?.node == gossip.member.node {
                    // We do NOT add gossip to payload if it's a gossip about target and target is suspect,
                    // this case was handled earlier and doing it here will lead to duplicate messages
                    ()
                } else {
                    membersToGossipAbout.append(gossip.member)
                }

                gossip.numberOfTimesGossiped += 1
                if self.settings.gossip.needsToBeGossipedMoreTimes(gossip, members: self.members.count) {
                    self._messagesToGossip.append(gossip)
                }
            }

            return .membership(membersToGossipAbout)
        }

        /// Adds `Member` to gossip messages.
        internal mutating func addToGossip(member: SWIM.Member<Peer>) {
            // we need to remove old state before we add the new gossip, so we don't gossip out stale state
            self._messagesToGossip.remove(where: { $0.member.peer.node == member.peer.node })
            self._messagesToGossip.append(.init(member: member, numberOfTimesGossiped: 0))
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: SWIM Member helper functions

extension SWIM.Instance {
    func notMyself(_ member: SWIM.Member<Peer>) -> Bool {
        self.whenMyself(member) == nil
    }

    func notMyself(_ peer: SWIMAddressablePeer) -> Bool {
        !self.isMyself(peer.node)
    }

    func isMyself(_ member: SWIM.Member<Peer>) -> Bool {
        self.isMyself(member.node)
    }

    func whenMyself(_ member: SWIM.Member<Peer>) -> SWIM.Member<Peer>? {
        if self.isMyself(member.peer) {
            return member
        } else {
            return nil
        }
    }

    func isMyself(_ peer: SWIMAddressablePeer) -> Bool {
        self.isMyself(peer.node)
    }

    func isMyself(_ node: Node) -> Bool {
        // we are exactly that node:
        self.node == node ||
            // ...or, the incoming node has no UID; there was no handshake made,
            // and thus the other side does not know which specific node it is going to talk to; as such, "we" are that node
            // as such, "we" are that node; we should never add such peer to our members, but we will reply to that node with "us" and thus
            // inform it about our specific UID, and from then onwards it will know about specifically this node (by replacing its UID-less version with our UID-ful version).
            self.node.withoutUID == node
    }

    /// Returns status of the passed in peer's member of the cluster, if known.
    ///
    /// - Parameter peer: the peer to look up the status for.
    /// - Returns: Status of the peer, if known.
    public func status(of peer: SWIMAddressablePeer) -> SWIM.Status? {
        if self.notMyself(peer) {
            return self._members[peer.node]?.status
        } else {
            // we consider ourselves always as alive (enables refuting others suspecting us)
            return .alive(incarnation: self.incarnation)
        }
    }

    /// Checks if the passed in peer is already a known member of the swim cluster.
    ///
    /// Note: `.dead` members are eventually removed from the swim instance and as such peers are not remembered forever!
    ///
    /// - parameters:
    ///   - peer: Peer to check if it currently is a member
    ///   - ignoreUID: Whether or not to ignore the peers UID, e.g. this is useful when issuing a "join 127.0.0.1:7337"
    ///                command, while being unaware of the nodes specific UID. When it joins, it joins with the specific UID after all.
    /// - Returns: true if the peer is currently a member of the swim cluster (regardless of status it is in)
    public func isMember(_ peer: SWIMAddressablePeer, ignoreUID: Bool = false) -> Bool {
        // the peer could be either:
        self.isMyself(peer) || // 1) "us" (i.e. the peer which hosts this SWIM instance, or
            self._members[peer.node] != nil || // 2) a "known member"
            (ignoreUID && peer.node.uid == nil && self._members.contains {
                // 3) a known member, however the querying peer did not know the real UID of the peer yet
                $0.key.withoutUID == peer.node
            })
    }

    /// Returns specific `SWIM.Member` instance for the passed in peer.
    ///
    /// - Parameter peer: peer whose member should be looked up (by its node identity, including the UID)
    /// - Returns: the peer's member instance, if it currently is a member of this cluster
    public func member(for peer: Peer) -> SWIM.Member<Peer>? {
        self.member(forNode: peer.node)
    }

    /// Returns specific `SWIM.Member` instance for the passed in node.
    ///
    /// - Parameter node: node whose member should be looked up (matching also by node UID)
    /// - Returns: the peer's member instance, if it currently is a member of this cluster
    public func member(forNode node: ClusterMembership.Node) -> SWIM.Member<Peer>? {
        self._members[node]
    }

    /// Count of only non-dead members.
    ///
    /// - SeeAlso: `SWIM.Status`
    public var notDeadMemberCount: Int {
        self._members.lazy.filter {
            !$0.value.isDead
        }.count
    }

    /// Count of all "other" members known to this instance (meaning members other than `myself`).
    ///
    /// This is equal to `n-1` where `n` is the number of nodes in the cluster.
    public var otherMemberCount: Int {
        self.allMemberCount - 1
    }

    /// Count of all members, including the myself node as well as any unreachable and dead nodes which are still kept in the membership.
    public var allMemberCount: Int {
        self._members.count
    }

    /// Lists all members known to this SWIM instance currently, potentially including even `.dead` nodes.
    ///
    /// - Complexity: O(1)
    /// - Returns: Returns all current members of the cluster, including suspect, unreachable and potentially dead members.
    public var members: SWIM.Membership<Peer> {
        self._members.values
    }

    /// Lists all `SWIM.Status.suspect` members.
    ///
    /// The `myself` member will never be suspect, as we always assume ourselves to be alive,
    /// even if all other cluster members think otherwise - this is what allows us to refute
    /// suspicions about our unreachability after all.
    ///
    /// - SeeAlso: `SWIM.Status.suspect`
    internal var suspects: [SWIM.Member<Peer>] {
        self.members.filter { $0.isSuspect }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Handling SWIM protocol interactions

extension SWIM.Instance {
    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: On Periodic Ping Tick Handler

    public mutating func onPeriodicPingTick() -> [PeriodicPingTickDirective] {
        defer {
            self.incrementProtocolPeriod()
        }

        var directives: [PeriodicPingTickDirective] = []

        // 1) always check suspicion timeouts, even if we no longer have anyone else to ping
        directives.append(contentsOf: self.checkSuspicionTimeouts())

        // 2) if we have someone to ping, let's do so
        if let toPing = self.nextPeerToPing() {
            directives.append(
                .sendPing(
                    target: toPing,
                    payload: self.makeGossipPayload(to: toPing),
                    timeout: self.dynamicLHMPingTimeout, sequenceNumber: self.nextSequenceNumber()
                )
            )
        }

        // 3) periodic cleanup of tombstones
        // TODO: could be optimized a bit to keep the "oldest one" and know if we have to scan already or not yet" etc
        if self.protocolPeriod % UInt64(self.settings.tombstoneCleanupIntervalInTicks) == 0 {
            cleanupTombstones()
        }

        // 3) ALWAYS schedule the next tick
        directives.append(.scheduleNextTick(delay: self.dynamicLHMProtocolInterval))

        return directives
    }

    /// Describes how a periodic tick should be handled.
    public enum PeriodicPingTickDirective {
        /// The membership has changed, e.g. a member was declared unreachable or dead and an event may need to be emitted.
        case membershipChanged(SWIM.MemberStatusChangedEvent<Peer>)
        /// Send a ping to the requested `target` peer using the provided timeout and sequenceNumber.
        case sendPing(target: Peer, payload: SWIM.GossipPayload<Peer>, timeout: Duration, sequenceNumber: SWIM.SequenceNumber)
        /// Schedule the next timer `onPeriodicPingTick` invocation in `delay` time.
        case scheduleNextTick(delay: Duration)
    }

    /// Check all suspects if any of them have been suspect for long enough that we should promote them to unreachable or dead.
    ///
    /// Suspicion timeouts are calculated taking into account the number of peers suspecting a given member (LHA-Suspicion).
    private mutating func checkSuspicionTimeouts() -> [PeriodicPingTickDirective] {
        var directives: [PeriodicPingTickDirective] = []

        for suspect in self.suspects {
            if case .suspect(_, let suspectedBy) = suspect.status {
                let suspicionTimeout = self.suspicionTimeout(suspectedByCount: suspectedBy.count)
                // proceed with suspicion escalation to .unreachable if the timeout period has been exceeded
                // We don't use Deadline because tests can override TimeSource
                guard let suspectSince = suspect.localSuspicionStartedAt,
                    self.isExpired(deadline: DispatchTime(uptimeNanoseconds: suspectSince.uptimeNanoseconds + UInt64(suspicionTimeout.nanoseconds))) else {
                    continue // skip, this suspect is not timed-out yet
                }

                guard let incarnation = suspect.status.incarnation else {
                    // suspect had no incarnation number? that means it is .dead already and should be recycled soon
                    continue
                }

                let newStatus: SWIM.Status
                if self.settings.unreachability == .enabled {
                    newStatus = .unreachable(incarnation: incarnation)
                } else {
                    newStatus = .dead
                }

                switch self.mark(suspect.peer, as: newStatus) {
                case .applied(let previousStatus, let member):
                    directives.append(.membershipChanged(SWIM.MemberStatusChangedEvent(previousStatus: previousStatus, member: member)))
                case .ignoredDueToOlderStatus:
                    continue
                }
            }
        }

        self.metrics.updateMembership(self.members)
        return directives
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: On Ping Handler

    public mutating func onPing(pingOrigin: PingOrigin, payload: SWIM.GossipPayload<Peer>, sequenceNumber: SWIM.SequenceNumber) -> [PingDirective] {
        var directives: [PingDirective]

        // 1) Process gossip
        directives = self.onGossipPayload(payload).map { g in
            .gossipProcessed(g)
        }

        // 2) Prepare reply
        directives.append(.sendAck(
            to: pingOrigin,
            pingedTarget: self.peer,
            incarnation: self.incarnation,
            payload: self.makeGossipPayload(to: pingOrigin),
            acknowledging: sequenceNumber
        ))

        return directives
    }

    /// Directs a shell implementation about how to handle an incoming `.ping`.
    public enum PingDirective {
        /// Indicates that incoming gossip was processed and the membership may have changed because of it,
        /// inspect the `GossipProcessedDirective` to learn more about what change was applied.
        case gossipProcessed(GossipProcessedDirective)

        /// Send an `ack` message.
        ///
        /// - parameters:
        ///   - to: the peer to which an `ack` should be sent
        ///   - pingedTarget: the `myself` peer, should be passed as `target` when sending the ack message
        ///   - incarnation: the incarnation number of this peer; used to determine which status is "the latest"
        ///     when comparing acknowledgement with suspicions
        ///   - payload: additional gossip payload to include in the ack message
        ///   - acknowledging: sequence number of the ack message
        case sendAck(
            to: PingOrigin,
            pingedTarget: Peer,
            incarnation: SWIM.Incarnation,
            payload: SWIM.GossipPayload<Peer>,
            acknowledging: SWIM.SequenceNumber
        )
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: On Ping Response Handlers

    public mutating func onPingResponse(response: SWIM.PingResponse<Peer, PingRequestOrigin>, pingRequestOrigin: PingRequestOrigin?, pingRequestSequenceNumber: SWIM.SequenceNumber?) -> [PingResponseDirective] {
        switch response {
        case .ack(let target, let incarnation, let payload, let sequenceNumber):
            return self.onPingAckResponse(target: target, incarnation: incarnation, payload: payload, pingRequestOrigin: pingRequestOrigin, pingRequestSequenceNumber: pingRequestSequenceNumber, sequenceNumber: sequenceNumber)
        case .nack(let target, let sequenceNumber):
            return self.onPingNackResponse(target: target, pingRequestOrigin: pingRequestOrigin, sequenceNumber: sequenceNumber)
        case .timeout(let target, let pingRequestOrigin, let timeout, _):
            return self.onPingResponseTimeout(target: target, timeout: timeout, pingRequestOrigin: pingRequestOrigin, pingRequestSequenceNumber: pingRequestSequenceNumber)
        }
    }

    mutating func onPingAckResponse(
        target pingedNode: Peer,
        incarnation: SWIM.Incarnation,
        payload: SWIM.GossipPayload<Peer>,
        pingRequestOrigin: PingRequestOrigin?,
        pingRequestSequenceNumber: SWIM.SequenceNumber?,
        sequenceNumber: SWIM.SequenceNumber
    ) -> [PingResponseDirective] {
        self.metrics.successfulPingProbes.increment()

        var directives: [PingResponseDirective] = []
        // We're proxying an ack payload from ping target back to ping source.
        // If ping target was a suspect, there'll be a refutation in a payload
        // and we probably want to process it asap. And since the data is already here,
        // processing this payload will just make gossip convergence faster.
        let gossipDirectives = self.onGossipPayload(payload)
        directives.append(contentsOf: gossipDirectives.map {
            PingResponseDirective.gossipProcessed($0)
        })

        self.log.debug("Received ack from [\(pingedNode)] with incarnation [\(incarnation)] and payload [\(payload)]", metadata: self.metadata)
        // The shell is already informed tha the member moved -> alive by the gossipProcessed directive
        _ = self.mark(pingedNode, as: .alive(incarnation: incarnation))

        if let pingRequestOrigin = pingRequestOrigin,
            let pingRequestSequenceNumber = pingRequestSequenceNumber {
            directives.append(
                .sendAck(
                    peer: pingRequestOrigin,
                    acknowledging: pingRequestSequenceNumber,
                    target: pingedNode,
                    incarnation: incarnation,
                    payload: payload
                )
            )
        } else {
            self.adjustLHMultiplier(.successfulProbe)
        }

        return directives
    }

    mutating func onPingNackResponse(
        target pingedNode: Peer,
        pingRequestOrigin: PingRequestOrigin?,
        sequenceNumber: SWIM.SequenceNumber
    ) -> [PingResponseDirective] {
        // yes, a nack is "successful" -- we did get a reply from the peer we contacted after all
        self.metrics.successfulPingProbes.increment()

        // Important:
        // We do _nothing_ here, however we actually handle nacks implicitly in today's SWIMNIO implementation...
        // This works because the arrival of the nack means we removed the callback from the handler,
        // so the timeout also is cancelled and thus no +1 will happen since the timeout will not trigger as well
        //
        // we should solve this more nicely, so any implementation benefits from this;
        // FIXME: .nack handling discussion https://github.com/apple/swift-cluster-membership/issues/52
        return []
    }

    mutating func onPingResponseTimeout(
        target: Peer,
        timeout: Duration,
        pingRequestOrigin: PingRequestOrigin?,
        pingRequestSequenceNumber: SWIM.SequenceNumber?
    ) -> [PingResponseDirective] {
        self.metrics.failedPingProbes.increment()

        var directives: [PingResponseDirective] = []
        if let pingRequestOrigin = pingRequestOrigin,
            let pingRequestSequenceNumber = pingRequestSequenceNumber {
            // Meaning we were doing a ping on behalf of the pingReq origin, we got a timeout, and thus need to report a nack back.
            directives.append(
                .sendNack(
                    peer: pingRequestOrigin,
                    acknowledging: pingRequestSequenceNumber,
                    target: target
                )
            )
            // Note that we do NOT adjust the LHM multiplier, this is on purpose.
            // We do not adjust it if we are only an intermediary.
        } else {
            // We sent a direct `.ping` and it timed out; we now suspect the target node and must issue additional ping requests.
            guard let pingedMember = self.member(for: target) else {
                return directives // seems we are not aware of this node, ignore it
            }
            guard let pingedMemberLastKnownIncarnation = pingedMember.status.incarnation else {
                return directives // so it is already dead, not need to suspect it
            }

            // The member should become suspect, it missed out ping/ack cycle:
            // we do not inform the shell about -> suspect moves; only unreachable or dead moves are of interest to it.
            _ = self.mark(pingedMember.peer, as: self.makeSuspicion(incarnation: pingedMemberLastKnownIncarnation))

            // adjust the LHM accordingly, we failed a probe (ping/ack) cycle
            self.adjustLHMultiplier(.failedProbe)

            // if we have other peers, we should ping request through them,
            // if not then there's no-one to ping request through and we just continue.
            if let pingRequestDirective = self.preparePingRequests(target: pingedMember.peer) {
                directives.append(.sendPingRequests(pingRequestDirective))
            }
        }

        return directives
    }

    /// Prepare ping request directives such that the shell can easily fire those messages
    mutating func preparePingRequests(target: Peer) -> SendPingRequestDirective? {
        guard let lastKnownStatus = self.status(of: target) else {
            // context.log.info("Skipping ping requests after failed ping to [\(toPing)] because node has been removed from member list") // FIXME allow logging
            return nil
        }

        // select random members to send ping requests to
        let membersToPingRequest = self.membersToPingRequest(target: target)

        guard !membersToPingRequest.isEmpty else {
            // no nodes available to ping, so we have to assume the node suspect right away
            guard let lastKnownIncarnation = lastKnownStatus.incarnation else {
                // log.debug("Not marking .suspect, as [\(target)] is already dead.") // "You are already dead!" // TODO logging
                return nil
            }

            switch self.mark(target, as: self.makeSuspicion(incarnation: lastKnownIncarnation)) {
            case .applied:
                // log.debug("No members to ping-req through, marked [\(target)] immediately as [\(currentStatus)].") // TODO: logging
                return nil
            case .ignoredDueToOlderStatus:
                // log.debug("No members to ping-req through to [\(target)], was already [\(currentStatus)].") // TODO: logging
                return nil
            }
        }

        let details = membersToPingRequest.map { member in
            SendPingRequestDirective.PingRequestDetail(
                peerToPingRequestThrough: member.peer,
                payload: self.makeGossipPayload(to: target),
                sequenceNumber: self.nextSequenceNumber()
            )
        }

        return SendPingRequestDirective(target: target, timeout: self.dynamicLHMPingTimeout, requestDetails: details)
    }

    /// Directs a shell implementation about how to handle an incoming `.pingRequest`.
    public enum PingResponseDirective {
        /// Indicates that incoming gossip was processed and the membership may have changed because of it,
        /// inspect the `GossipProcessedDirective` to learn more about what change was applied.
        case gossipProcessed(GossipProcessedDirective)

        /// Upon receiving an `ack` from `target`, if we were making this ping because of a `pingRequest` from `peer`,
        /// we need to forward that acknowledgement to that peer now.
        ///
        /// - parameters:
        ///   - to: the peer to which an `ack` should be sent
        ///   - pingedTarget: the `myself` peer, should be passed as `target` when sending the ack message
        ///   - incarnation: the incarnation number of this peer; used to determine which status is "the latest"
        ///     when comparing acknowledgement with suspicions
        ///   - payload: additional gossip payload to include in the ack message
        ///   - acknowledging: sequence number of the ack message
        case sendAck(peer: PingRequestOrigin, acknowledging: SWIM.SequenceNumber, target: Peer, incarnation: UInt64, payload: SWIM.GossipPayload<Peer>)

        /// Send a `nack` to the `peer` which originally send this peer request.
        ///
        /// - parameters:
        ///   - peer: the peer to which the `nack` should be sent
        ///   - acknowledging: sequence number of the ack message
        ///   - target: the peer which we attempted to ping but it didn't reply on time
        case sendNack(peer: PingRequestOrigin, acknowledging: SWIM.SequenceNumber, target: Peer)

        /// Send a `pingRequest` as described by the `SendPingRequestDirective`.
        ///
        /// The target node did not reply with an successful `.ack` and as such was now marked as `.suspect`.
        /// By sending ping requests to other members of the cluster we attempt to revert this suspicion,
        /// perhaps some other node is able to receive an `.ack` from it after all?
        case sendPingRequests(SendPingRequestDirective)
    }

    /// Describes how a pingRequest should be performed.
    ///
    /// Only a single `target` peer is used, however it may be pinged "through" a few other members.
    /// The amount of fan-out in pingRequests is configurable by `swim.indirectProbeCount`.
    public struct SendPingRequestDirective {
        /// Target that the should be probed by the `requestDetails.memberToPingRequestThrough` peers.
        public let target: Peer
        /// Timeout to be used for all the ping requests about to be sent.
        public let timeout: Duration
        /// Describes the details how each ping request should be performed.
        public let requestDetails: [PingRequestDetail]

        /// Describes a specific ping request to be made.
        public struct PingRequestDetail {
            /// Marks the peer the `pingRequest` should be sent to.
            public let peerToPingRequestThrough: Peer
            /// Additional gossip to carry with the `pingRequest`
            public let payload: SWIM.GossipPayload<Peer>
            /// Sequence number to assign to this `pingRequest`.
            public let sequenceNumber: SWIM.SequenceNumber
        }
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: On Ping Request

    public mutating func onPingRequest(
        target: Peer,
        pingRequestOrigin: PingRequestOrigin,
        payload: SWIM.GossipPayload<Peer>,
        sequenceNumber: SWIM.SequenceNumber
    ) -> [PingRequestDirective] {
        var directives: [PingRequestDirective] = []

        // 1) Process gossip
        let gossipDirectives: [PingRequestDirective] = self.onGossipPayload(payload).map { directive in
            .gossipProcessed(directive)
        }
        directives.append(contentsOf: gossipDirectives)

        // 2) Process the ping request itself
        guard self.notMyself(target) else {
            self.log.debug("Received pingRequest to ping myself myself, ignoring.", metadata: self.metadata([
                "swim/pingRequestOrigin": "\(pingRequestOrigin)",
                "swim/pingSequenceNumber": "\(sequenceNumber)",
            ]))
            return directives
        }

        if !self.isMember(target) {
            // The case when member is a suspect is already handled in `processGossipPayload`,
            // since payload will always contain suspicion about target member; no need to inform the shell again about this
            _ = self.addMember(target, status: .alive(incarnation: 0))
        }

        let pingSequenceNumber = self.nextSequenceNumber()
        // Indirect ping timeout should always be shorter than pingRequest timeout.
        // Setting it to a fraction of initial ping timeout as suggested in the original paper.
        // - SeeAlso: Local Health Multiplier (LHM)
        let indirectPingTimeout = Duration.nanoseconds(
            Int(Double(self.settings.pingTimeout.nanoseconds) * self.settings.lifeguard.indirectPingTimeoutMultiplier)
        )

        directives.append(
            .sendPing(
                target: target,
                payload: self.makeGossipPayload(to: target),
                pingRequestOrigin: pingRequestOrigin,
                pingRequestSequenceNumber: sequenceNumber,
                timeout: indirectPingTimeout,
                pingSequenceNumber: pingSequenceNumber
            )
        )

        return directives
    }

    /// Directs a shell implementation about how to handle an incoming `.pingRequest`.
    public enum PingRequestDirective {
        /// Indicates that incoming gossip was processed and the membership may have changed because of it,
        /// inspect the `GossipProcessedDirective` to learn more about what change was applied.
        case gossipProcessed(GossipProcessedDirective)
        /// Send a ping to the requested `target` peer using the provided timeout and sequenceNumber.
        ///
        /// - parameters:
        ///   - target: the target peer which should be probed
        ///   - payload: gossip information to be processed by this peer,
        ///     resulting in potentially discovering new information about other members of the cluster
        ///   - pingRequestOrigin: peer on whose behalf we are performing this indirect ping;
        ///     it will be useful to pipe back replies from the target to the origin member.
        ///   - pingRequestSequenceNumber: sequence number that must be used when replying to the `pingRequestOrigin`
        ///   - timeout: timeout to be used when performing the ping probe (it MAY be smaller than a normal direct ping probe's timeout)
        ///   - pingSequenceNumber: sequence number to use for the `ping` message
        case sendPing(
            target: Peer,
            payload: SWIM.GossipPayload<Peer>,
            pingRequestOrigin: PingRequestOrigin,
            pingRequestSequenceNumber: SWIM.SequenceNumber,
            timeout: Duration,
            pingSequenceNumber: SWIM.SequenceNumber
        )
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: On Ping Request Response

    /// This should be called on first successful (non-nack) pingRequestResponse
    public mutating func onPingRequestResponse(_ response: SWIM.PingResponse<Peer, PingRequestOrigin>, pinged pingedPeer: Peer) -> [PingRequestResponseDirective] {
        guard let previousStatus = self.status(of: pingedPeer) else {
            // we do not process replies from an unknown member; it likely means we have removed it already for some reason.
            return [.unknownMember]
        }
        var directives: [PingRequestResponseDirective] = []

        switch response {
        case .ack(let target, let incarnation, let payload, _):
            assert(
                target.node == pingedPeer.node,
                "The ack.from member [\(target)] MUST be equal to the pinged member \(pingedPeer.node)]; The Ack message is being forwarded back to us from the pinged member."
            )

            let gossipDirectives = self.onGossipPayload(payload)
            directives += gossipDirectives.map {
                PingRequestResponseDirective.gossipProcessed($0)
            }

            switch self.mark(pingedPeer, as: .alive(incarnation: incarnation)) {
            case .applied:
                directives.append(.alive(previousStatus: previousStatus))
                return directives
            case .ignoredDueToOlderStatus(let currentStatus):
                directives.append(.ignoredDueToOlderStatus(currentStatus: currentStatus))
                return directives
            }
        case .nack:
            // TODO: this should never happen. How do we express it?
            directives.append(.nackReceived)
            return directives

        case .timeout:
            switch previousStatus {
            case .alive(let incarnation),
                 .suspect(let incarnation, _):
                switch self.mark(pingedPeer, as: self.makeSuspicion(incarnation: incarnation)) {
                case .applied:
                    directives.append(.newlySuspect(previousStatus: previousStatus, suspect: self.member(forNode: pingedPeer.node)!))
                    return directives
                case .ignoredDueToOlderStatus(let status):
                    directives.append(.ignoredDueToOlderStatus(currentStatus: status))
                    return directives
                }
            case .unreachable:
                directives.append(.alreadyUnreachable)
                return directives
            case .dead:
                directives.append(.alreadyDead)
                return directives
            }
        }
    }

    public mutating func onEveryPingRequestResponse(_ result: SWIM.PingResponse<Peer, PingRequestOrigin>, pinged peer: Peer) -> [PingRequestResponseDirective] {
        switch result {
        case .timeout:
            // Failed pingRequestResponse indicates a missed nack, we should adjust LHMultiplier
            self.metrics.failedPingRequestProbes.increment()
            self.adjustLHMultiplier(.probeWithMissedNack)
        case .ack, .nack:
            // Successful pingRequestResponse should be handled only once (and thus in `onPingRequestResponse` only),
            // however we can nicely handle all responses here for purposes of metrics (and NOT adjust them in the onPingRequestResponse
            // since that would lead to double-counting successes)
            self.metrics.successfulPingRequestProbes.increment()
        }

        return [] // just so happens that we never actually perform any actions here (so far, keeping the return type for future compatibility)
    }

    /// Directs a shell implementation about how to handle an incoming ping request response.
    public enum PingRequestResponseDirective {
        /// Indicates that incoming gossip was processed and the membership may have changed because of it,
        /// inspect the `GossipProcessedDirective` to learn more about what change was applied.
        case gossipProcessed(GossipProcessedDirective)

        case alive(previousStatus: SWIM.Status) // TODO: offer a membership change option rather?
        case nackReceived
        /// Indicates that the `target` of the ping response is not known to this peer anymore,
        /// it could be that we already marked it as dead and removed it.
        ///
        /// No additional action, except optionally some debug logging should be performed.
        case unknownMember
        case newlySuspect(previousStatus: SWIM.Status, suspect: SWIM.Member<Peer>)
        case alreadySuspect
        case alreadyUnreachable
        case alreadyDead
        /// The incoming gossip is older than already known information about the target peer (by incarnation), and was (safely) ignored.
        /// The current status of the peer is as returned in `currentStatus`.
        case ignoredDueToOlderStatus(currentStatus: SWIM.Status)
    }

    internal mutating func onGossipPayload(_ payload: SWIM.GossipPayload<Peer>) -> [GossipProcessedDirective] {
        switch payload {
        case .none:
            return []
        case .membership(let members):
            return members.flatMap { member in
                self.onGossipPayload(about: member)
            }
        }
    }

    internal mutating func onGossipPayload(about member: SWIM.Member<Peer>) -> [GossipProcessedDirective] {
        if self.isMyself(member) {
            return [self.onMyselfGossipPayload(myself: member)]
        } else {
            return self.onOtherMemberGossipPayload(member: member)
        }
    }

    /// ### Unreachability status handling
    /// Performs all special handling of `.unreachable` such that if it is disabled members are automatically promoted to `.dead`.
    /// See `settings.unreachability` for more details.
    private mutating func onMyselfGossipPayload(myself incoming: SWIM.Member<Peer>) -> GossipProcessedDirective {
        assert(
            self.peer.node == incoming.peer.node,
            """
            Attempted to process gossip as-if about myself, but was not the same peer, was: \(incoming.peer.node.detailedDescription). \
            Myself: \(self.peer)
            SWIM.Instance: \(self)
            """
        )

        // Note, we don't yield changes for myself node observations, thus the self node will never be reported as unreachable,
        // after all, we can always reach ourselves. We may reconsider this if we wanted to allow SWIM to inform us about
        // the fact that many other nodes think we're unreachable, and thus we could perform self-downing based upon this information

        switch incoming.status {
        case .alive:
            // as long as other nodes see us as alive, we're happy
            return .applied(change: nil)
        case .suspect(let suspectedInIncarnation, _):
            // someone suspected us, so we need to increment our incarnation number to spread our alive status with
            // the incremented incarnation
            if suspectedInIncarnation == self.incarnation {
                self.adjustLHMultiplier(.refutingSuspectMessageAboutSelf)
                self.nextIncarnation()
                // refute the suspicion, we clearly are still alive
                self.addToGossip(member: self.member)
                return .applied(change: nil)
            } else if suspectedInIncarnation > self.incarnation {
                self.log.warning(
                    """
                    Received gossip about self with incarnation number [\(suspectedInIncarnation)] > current incarnation [\(self._incarnation)], \
                    which should never happen and while harmless is highly suspicious, please raise an issue with logs. This MAY be an issue in the library.
                    """)
                return .applied(change: nil)
            } else {
                // incoming incarnation was < than current one, i.e. the incoming information is "old" thus we discard it
                return .applied(change: nil)
            }

        case .unreachable(let unreachableInIncarnation):
            switch self.settings.unreachability {
            case .enabled:
                // someone suspected us,
                // so we need to increment our incarnation number to spread our alive status with the incremented incarnation
                if unreachableInIncarnation == self.incarnation {
                    self.nextIncarnation()
                    return .ignored
                } else if unreachableInIncarnation > self.incarnation {
                    self.log.warning("""
                    Received gossip about self with incarnation number [\(unreachableInIncarnation)] > current incarnation [\(self._incarnation)], \
                    which should never happen and while harmless is highly suspicious, please raise an issue with logs. This MAY be an issue in the library.
                    """)
                    return .applied(change: nil)
                } else {
                    self.log.debug("Incoming .unreachable about myself, however current incarnation [\(self.incarnation)] is greater than incoming \(incoming.status)")
                    return .ignored
                }

            case .disabled:
                // we don't use unreachable states, and in any case, would not apply it to myself
                // as we always consider "us" to be reachable after all
                return .ignored
            }

        case .dead:
            guard var myselfMember = self.member(for: self.peer) else {
                return .applied(change: nil)
            }

            myselfMember.status = .dead
            switch self.mark(self.peer, as: .dead) {
            case .applied(.some(let previousStatus), _):
                return .applied(change: .init(previousStatus: previousStatus, member: myselfMember))
            default:
                self.log.warning("\(self.peer) already marked .dead", metadata: self.metadata)
                return .ignored
            }
        }
    }

    /// ### Unreachability status handling
    /// Performs all special handling of `.unreachable` such that if it is disabled members are automatically promoted to `.dead`.
    /// See `settings.unreachability` for more details.
    private mutating func onOtherMemberGossipPayload(member: SWIM.Member<Peer>) -> [GossipProcessedDirective] {
        assert(self.node != member.node, "Attempted to process gossip as-if not-myself, but WAS same peer, was: \(member). Myself: \(self.peer, orElse: "nil")")

        guard self.isMember(member.peer) else {
            // it's a new node it seems

            guard member.node.uid != nil else {
                self.log.debug("Incoming member has no `uid`, ignoring; cannot add members to membership without uid", metadata: self.metadata([
                    "member": "\(member)",
                    "member/node": "\(member.node.detailedDescription)",
                ]))
                return []
            }

            // the Shell may need to set up a connection if we just made a move from previousStatus: nil,
            // so we definitely need to emit this change
            return self.addMember(member.peer, status: member.status).compactMap { directive in
                switch directive {
                case .added(let member):
                    return .applied(change: SWIM.MemberStatusChangedEvent(previousStatus: nil, member: member))
                case .previousHostPortMemberConfirmedDead(let change):
                    return .applied(change: change)
                case .memberAlreadyKnownDead:
                    return nil
                case .newerMemberAlreadyPresent(let member):
                    return .applied(change: SWIM.MemberStatusChangedEvent(previousStatus: nil, member: member))
                }
            }
        }

        var directives: [GossipProcessedDirective] = []
        switch self.mark(member.peer, as: member.status) {
        case .applied(let previousStatus, let member):
            if member.status.isSuspect, previousStatus?.isAlive ?? false {
                self.log.debug("Member [\(member.peer.node, orElse: "<unknown-node>")] marked as suspect, via incoming gossip", metadata: self.metadata)
            }
            directives.append(.applied(change: .init(previousStatus: previousStatus, member: member)))

        case .ignoredDueToOlderStatus(let currentStatus):
            self.log.trace("Gossip about member \(member.node), incoming: [\(member.status)] does not supersede current: [\(currentStatus)]", metadata: self.metadata)
        }

        return directives
    }

    /// Indicates the gossip payload was processed and changes to the membership were made.
    public enum GossipProcessedDirective: Equatable {
        /// The gossip was applied to the local membership view and an event may want to be emitted for it.
        ///
        /// It is up to the shell implementation which events are published, but generally it is recommended to
        /// only publish changes which are `SWIM.MemberStatusChangedEvent.isReachabilityChange` as those can and should
        /// usually be acted on by high level implementations.
        ///
        /// Changes between alive and suspect are an internal implementation detail of SWIM,
        /// and usually do not need to be emitted as events to users.
        ///
        /// ### Note for connection based implementations
        /// You may need to establish a new connection if the changes' `previousStatus` is `nil`, as it means we have
        /// not seen this member before and in order to send messages to it, one may want to eagerly establish a connection to it.
        case applied(change: SWIM.MemberStatusChangedEvent<Peer>?)

        static var ignored: Self {
            .applied(change: nil)
        }
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Confirm Dead

    public mutating func confirmDead(peer: Peer) -> ConfirmDeadDirective {
        if self.member(for: peer) == nil,
            self._members.first(where: { $0.key == peer.node }) == nil {
            return .ignored // this peer is absolutely unknown to us, we should not even emit events about it
        }

        switch self.mark(peer, as: .dead) {
        case .applied(let previousStatus, let member):
            return .applied(change: SWIM.MemberStatusChangedEvent(previousStatus: previousStatus, member: member))

        case .ignoredDueToOlderStatus:
            return .ignored // it was already dead for example
        }
    }

    /// Directs how to handle the result of a `confirmDead` call.
    public enum ConfirmDeadDirective {
        /// The change was applied and caused a membership change.
        ///
        /// The change should be emitted as an event by an interpreting shell.
        case applied(change: SWIM.MemberStatusChangedEvent<Peer>)

        /// The confirmation had not effect, either the peer was not known, or is already dead.
        case ignored
    }

    /// Returns if this node is known to have already been marked dead at some point.
    func hasTombstone(_ node: Node) -> Bool {
        guard let uid = node.uid else {
            return false
        }

        let anythingAsNotTakenIntoAccountInEquality: UInt64 = 0
        return self.removedDeadMemberTombstones.contains(.init(uid: uid, deadlineProtocolPeriod: anythingAsNotTakenIntoAccountInEquality))
    }

    private mutating func cleanupTombstones() { // time to cleanup the tombstones
        self.removedDeadMemberTombstones = self.removedDeadMemberTombstones.filter {
            // keep the ones where their deadline is still in the future
            self.protocolPeriod < $0.deadlineProtocolPeriod
        }
    }

    /// Used to store known "confirmed dead" member unique identifiers.
    struct MemberTombstone: Hashable {
        /// UID of the dead member
        let uid: UInt64
        /// After how many protocol periods ("ticks") should this tombstone be cleaned up
        let deadlineProtocolPeriod: UInt64

        func hash(into hasher: inout Hasher) {
            hasher.combine(self.uid)
        }

        static func == (lhs: MemberTombstone, rhs: MemberTombstone) -> Bool {
            lhs.uid == rhs.uid
        }
    }
}

extension SWIM.Instance: CustomDebugStringConvertible {
    public var debugDescription: String {
        // multi-line on purpose
        """
        SWIM.Instance(
            settings: \(settings),
            
            myself: \(String(reflecting: peer)),
                                
            _incarnation: \(_incarnation),
            _protocolPeriod: \(_protocolPeriod), 

            members: [
                \(_members.map { "\($0.key)" }.joined(separator: "\n        "))
            ] 
            membersToPing: [ 
                \(membersToPing.map { "\($0)" }.joined(separator: "\n        "))
            ]
             
            _messagesToGossip: \(_messagesToGossip)
        )
        """
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: SWIM Lifeguard Local Health Modifier event

extension SWIM.Instance {
    /// Events which cause the modification of the Local health aware Multiplier to be adjusted.
    ///
    /// The LHM is increased (in increments of `1`) whenever an event occurs that indicates that the instance
    /// is not processing incoming messages in timely order.
    ///
    /// It is decreased and decreased (by `1`), whenever it processes a successful ping/ack cycle,
    /// meaning that is is healthy and properly processing incoming messages on time.
    ///
    /// - SeeAlso: Lifeguard IV.A. Local Health Aware Probe, which describes the rationale behind the events.
    public enum LHModifierEvent: Equatable {
        /// A successful ping/ack probe cycle was completed.
        case successfulProbe
        /// A direct ping/ack cycle has failed (timed-out).
        case failedProbe
        /// Some other member has suspected this member, and we had to refute the suspicion.
        case refutingSuspectMessageAboutSelf
        /// During a `pingRequest` the ping request origin (us) received a timeout without seeing `.nack`
        /// from the intermediary member; This could mean we are having network trouble and are a faulty node.
        case probeWithMissedNack

        /// - Returns: by how much the LHM should be adjusted in response to this event.
        ///   The adjusted value MUST be clamped between `0 <= value <= maxLocalHealthMultiplier`
        var lhmAdjustment: Int {
            switch self {
            case .successfulProbe:
                return -1 // decrease the LHM
            case .failedProbe,
                 .refutingSuspectMessageAboutSelf,
                 .probeWithMissedNack:
                return 1 // increase the LHM
            }
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: SWIM Logging Metadata

extension SWIM.Instance {
    /// Allows for convenient adding of additional metadata to the `SWIM.Instance.metadata`.
    public func metadata(_ additional: Logger.Metadata) -> Logger.Metadata {
        var metadata = self.metadata
        metadata.merge(additional, uniquingKeysWith: { _, r in r })
        return metadata
    }

    /// While the SWIM.Instance is not meant to be logging by itself, it does offer metadata for loggers to use.
    public var metadata: Logger.Metadata {
        [
            "swim/protocolPeriod": "\(self.protocolPeriod)",
            "swim/timeoutSuspectsBeforePeriodMax": "\(self.timeoutSuspectsBeforePeriodMax)",
            "swim/timeoutSuspectsBeforePeriodMin": "\(self.timeoutSuspectsBeforePeriodMin)",
            "swim/incarnation": "\(self.incarnation)",
            "swim/members/all": Logger.Metadata.Value.array(self.members.map { "\(reflecting: $0)" }),
            "swim/members/count": "\(self.notDeadMemberCount)",
            "swim/suspects/count": "\(self.suspects.count)",
        ]
    }
}
