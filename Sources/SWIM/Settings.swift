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

#if os(macOS) || os(iOS) || os(watchOS) || os(tvOS)
import func Darwin.log2
#else
import Glibc
#endif

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: SWIM Settings

extension SWIM {
    /// Settings generally applicable to the SWIM implementation as well as any shell running it.
    public struct Settings {
        /// Create default settings.
        public init() {}

        /// Logger used by the instance and shell (unless the specific shell implementation states otherwise).
        public var logger: Logger = Logger(label: "swim")

        /// Convenience setting to change the `logger`'s log level.
        public var logLevel: Logger.Level {
            get {
                self.logger.logLevel
            }
            set {
                self.logger.logLevel = newValue
            }
        }

        /// Gossip settings, configures how the protocol period time intervals and gossip characteristics.
        public var gossip: SWIMGossipSettings = .init()

        /// Settings of the Lifeguard extensions to the SWIM protocol.
        public var lifeguard: SWIMLifeguardSettings = .init()

        /// Settings for metrics to be emitted by the SWIM.Instance automatically.
        public var metrics: SWIMMetricsSettings = .init()

        /// Configures the node of this SWIM instance explicitly, including allowing setting it's UID.
        ///
        /// Depending on runtime, setting this value explicitly may not be necessary,
        /// as the node can be inferred from the host/port the specific shell is bound to.
        ///
        /// If neither, the node could be inferred, or is set explicitly, a fatal crash should be caused by the SWIM shell implementation.
        public var node: Node?

        /// Number of indirect probes that will be issued once a direct ping probe has failed to reply in time with an ack.
        ///
        /// In case of small clusters where nr. of neighbors is smaller than this value, the most neighbors available will
        /// be asked to issue an indirect probe. E.g. a 3 node cluster, configured with `indirectChecks = 3` has only `1`
        /// remaining node it can ask for an indirect probe (since 1 node is ourselves, and 1 node is the potentially suspect node itself).
        public var indirectProbeCount: Int = 3 {
            willSet {
                precondition(newValue >= 0, "`indirectChecks` MUST be >= 0. It is recommended to have it be no lower than 3.")
            }
        }

        /// When a member is "confirmed dead" we stop gossiping about it and in order to prevent a node to accidentally
        /// re-join the cluster by us having fully forgotten about it while it still remains lingering around, we use tombstones.
        ///
        /// The time to live configures how long the tombstones are kept around, meaning some accumulating overhead,
        /// however added safety in case the node "comes back". Note that this may be solved on higher level layers
        /// e.g. by forbidding such node to even form a connection to us in a connection-ful implementation, in such case
        /// lower timeouts are permittable.
        ///
        /// Assuming a default of 1 second per protocol period (probe interval), the default value results in 4 hours of delay.
        public var tombstoneTimeToLiveInTicks: UInt64 =
            4 * 60 * 60

        /// An interval, as expressed in number of `probeInterval` ticks.
        ///
        /// Every so often the additional task of checking the accumulated tombstones for any overdue ones (see `tombstoneTimeToLive`),
        /// will be performed. Outdated tombstones are then removed. This is done this way to benefit from using a plain Set of the tombstones
        /// for the checking if a peer has a tombstone or not (O(1), performed frequently), while only having to clean them up periodically (O(n)).
        public var tombstoneCleanupIntervalInTicks: Int = 5 * 60 {
            willSet {
                precondition(newValue > 0, "`tombstoneCleanupIntervalInTicks` MUST be > 0")
            }
        }

        /// Optional feature: Set of "initial contact points" to automatically contact and join upon starting a node
        ///
        /// Optionally, a Shell implementation MAY use this setting automatically contact a set of initial contact point nodes,
        /// allowing a new member to easily join existing clusters (e.g. if there is one "known" address to contact upon starting).
        ///
        /// Consult your Shell implementations of frameworks' documentation if this feature is supported, or handled in alternative ways.
        /// // TODO: This could be made more generic with "pluggable" discovery mechanism.
        ///
        /// Note: This is sometimes also referred to "seed nodes" and a "seed node join process".
        public var initialContactPoints: Set<ClusterMembership.Node> = []

        /// Interval at which gossip messages should be issued.
        /// This property sets only a base value of probe interval, which will later be multiplied by `SWIM.Instance.localHealthMultiplier`.
        /// - SeeAlso: `maxLocalHealthMultiplier`
        /// Every `interval` a `fan-out` number of gossip messages will be sent.
        public var probeInterval: Duration = .seconds(1)

        /// Time amount after which a sent ping without ack response is considered timed-out.
        /// This drives how a node becomes a suspect, by missing such ping/ack rounds.
        ///
        /// This property sets only a base timeout value, which is later multiplied by `localHealthMultiplier`
        /// Note that after an initial ping/ack timeout, secondary indirect probes are issued,
        /// and only after exceeding `suspicionTimeoutPeriodsMax` shall the node be declared as `.unreachable`,
        /// which results in an `Cluster.MemberReachabilityChange` `Cluster.Event` which downing strategies may act upon.
        ///
        /// - Note: Ping timeouts generally should be set as a multiple of the RTT (round-trip-time) expected in the deployment environment.
        ///
        /// - SeeAlso: `SWIMLifeguardSettings.maxLocalHealthMultiplier` which affects the "effective" ping timeouts used in runtime.
        public var pingTimeout: Duration = .milliseconds(300)

        /// Optional SWIM Protocol Extension: `SWIM.MemberStatus.unreachable`
        ///
        /// This is a custom extension to the standard SWIM statuses which first moves a member into unreachable state,
        /// while still trying to ping it, while awaiting for a final "mark it `.dead` now" from an external system.
        ///
        /// This allows for collaboration between external and internal monitoring systems before committing a node as `.dead`.
        /// The `.unreachable` state IS gossiped throughout the cluster same as alive/suspect are, while a `.dead` member is not gossiped anymore,
        /// as it is effectively removed from the membership. This allows for additional spreading of the unreachable observation throughout
        /// the cluster, as an observation, but not as an action (of removing given member).
        ///
        /// The `.unreachable` state therefore from a protocol perspective, is equivalent to a `.suspect` member status.
        ///
        /// Unless you _know_ you need un-reachability, do not enable this mode, as it requires additional actions to be taken,
        /// to confirm a node as dead, complicating the failure detection and node pruning.
        ///
        /// By default this option is disabled, and the SWIM implementation behaves same as documented in the papers,
        /// meaning that when a node remains unresponsive for an exceeded amount of time it is marked as `.dead` immediately.
        public var unreachability: UnreachabilitySettings = .disabled

        /// Configure how unreachability should be handled by this instance.
        public enum UnreachabilitySettings {
            /// Do not use the .unreachable state and just like classic SWIM automatically announce a node as `.dead`,
            /// if failure detection triggers.
            ///
            /// Warning: DO NOT run clusters with mixed reachability settings.
            ///     In mixed deployments having a single node not understand unreachability will result
            ///     in it promoting an incoming `.unreachable` status to `.dead` and continue spreading this information.
            ///
            ///     This can defeat the purpose of unreachability, as it can be used to wait to announce the final `.dead`,
            ///     move after consulting an external participant, and with a node unaware of unreachability
            ///     this would short-circut this "wait for decision".
            case disabled
            /// Enables the `.unreachable` status extension.
            /// Most deployments will not need to utilize this mode.
            ///
            /// Reachability changes are emitted as `SWIM.MemberStatusChangedEvent` and allow an external participant to
            /// decide the final `confirmDead` which should be invoked on the swim instance when decided.
            ///
            /// For other intents and purposes, unreachable is operationally equivalent to a suspect node,
            /// in that it MAY return to being alive again.
            case enabled
        }

        /// This is not a part of public API. SWIM is using time to schedule pings/calculate timeouts.
        /// When designing tests one may want to simulate scenarios when events are coming in particular order.
        /// Doing this will require some control over SWIM's notion of time.
        ///
        /// This property allows to override the `.now()` function for mocking purposes.
        internal var timeSourceNow: () -> DispatchTime = { () -> DispatchTime in
            DispatchTime.now()
        }

        #if TRACELOG_SWIM
        /// When enabled traces _all_ incoming SWIM protocol communication (remote messages).
        public var traceLogLevel: Logger.Level? = .warning
        #else
        /// When enabled traces _all_ incoming SWIM protocol communication (remote messages).
        public var traceLogLevel: Logger.Level?
        #endif
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: SWIM Gossip Settings

/// Settings specific to the gossip payloads used in the SWIM gossip dissemination subsystem.
public struct SWIMGossipSettings {
    /// Create default settings.
    public init() {}

    /// Limits the number of `GossipPayload`s to be piggy-backed in a single message.
    ///
    /// Notes: The Ping/Ack messages are used to piggy-back the gossip information along those messages.
    /// In order to prevent these messages from growing too large, heuristics or a simple limit must be imposed on them/
    /// Currently, we limit the message sizes by simply counting how many gossip payloads are allowed to be carried.
    public var maxNumberOfMessagesPerGossip: Int = 12

    /// Each gossip (i.e. an observation by this specific node of a specific node's specific status),
    /// is gossiped only a limited number of times, after which the algorithms
    ///
    /// - parameters:
    ///   - n: total number of cluster members (including myself), MUST be >= 1 (or will crash)
    ///
    /// - SeeAlso: SWIM 4.1. Infection-Style Dissemination Component
    /// - SeeAlso: SWIM 5. Performance Evaluation of a Prototype
    public func gossipedEnoughTimes(_ gossip: SWIM.Gossip<some SWIMPeer>, members n: Int) -> Bool {
        precondition(n >= 1, "number of members MUST be >= 1")
        guard n > 1 else {
            // no need to gossip ever in a single node cluster
            return false
        }
        let maxTimesDouble = self.gossipedEnoughTimesBaseMultiplier * log2(Double(n + 1))
        return gossip.numberOfTimesGossiped > Int(maxTimesDouble)
    }

    internal func needsToBeGossipedMoreTimes(_ gossip: SWIM.Gossip<some SWIMPeer>, members n: Int) -> Bool {
        !self.gossipedEnoughTimes(gossip, members: n)
    }

    /// Used to adjust the `gossipedEnoughTimes` value.
    ///
    /// Should not be lower than 3, since for
    ///
    /// - SeeAlso: SWIM 5. Performance Evaluation of a Prototype
    public var gossipedEnoughTimesBaseMultiplier: Double = 3 {
        willSet {
            precondition(newValue > 0, "number of members MUST be > 0")
            self.gossipedEnoughTimesBaseMultiplier = newValue
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: SWIM Lifeguard extensions Settings

/// Lifeguard is a set of extensions to SWIM that helps reducing false positive failure detections.
///
/// - SeeAlso: [Lifeguard: Local Health Awareness for More Accurate Failure Detection](https://arxiv.org/pdf/1707.00788.pdf)
public struct SWIMLifeguardSettings {
    /// Create default settings.
    public init() {}

    /// Local health multiplier is a part of Lifeguard extensions to SWIM.
    /// It will increase local probe interval and probe timeout if the instance is not processing messages in timely manner.
    /// This property will define the upper limit to local health multiplier.
    ///
    /// Must be greater than 0. To effectively disable the LHM extension you may set this to `1`.
    ///
    /// - SeeAlso: [Lifeguard IV.A. Local Health Multiplier (LHM)](https://arxiv.org/pdf/1707.00788.pdf)
    public var maxLocalHealthMultiplier: Int = 8 {
        willSet {
            precondition(newValue >= 0, "Local health multiplier MUST BE >= 0")
        }
    }

    /// Suspicion timeouts are specified as number of probe intervals.
    ///
    /// E.g. a `suspicionTimeoutMax = .seconds(10)` means that a suspicious node will be escalated as `.unreachable`  at most after approximately 10 seconds. Suspicion timeout will decay logarithmically to `suspicionTimeoutMin`
    /// with additional suspicions arriving. When no additional suspicions present, suspicion timeout will equal `suspicionTimeoutMax`
    ///
    /// ### Modification:
    /// We introduce an extra state of "unreachable" is introduced, which is signalled to a high-level membership implementation,
    /// which may then confirm it, then leading the SWIM membership to mark the given member as `.dead`. Unlike the original SWIM/Lifeguard
    /// implementations which proceed to `.dead` automatically. This separation allows running with SWIM failure detection in an "informational"
    /// mode.
    ///
    /// Once it is confirmed dead by the high-level membership (e.g. immediately, or after an additional grace period, or vote),
    /// it will be marked `.dead` in SWIM, and `.down` in the high-level membership.
    ///
    /// - SeeAlso: [Lifeguard IV.B. Local Health Aware Suspicion (LHA-Suspicion)](https://arxiv.org/pdf/1707.00788.pdf)
    public var suspicionTimeoutMax: Duration = .seconds(10) {
        willSet {
            precondition(newValue.nanoseconds >= self.suspicionTimeoutMin.nanoseconds, "`suspicionTimeoutMax` MUST BE >= `suspicionTimeoutMin`")
        }
    }

    /// To ensure ping origin have time to process .nack, indirect ping timeout should always be shorter than originator's timeout
    /// This property controls a multiplier that's applied to `pingTimeout` when calculating indirect probe timeout.
    /// The default of 80% follows a proposal in the initial paper.
    /// The value should be between 0 and 1 (exclusive).
    ///
    /// - SeeAlso: `pingTimeout`
    /// - SeeAlso: [Lifeguard IV.B. Local Health Aware Suspicion (LHA-Suspicion)](https://arxiv.org/pdf/1707.00788.pdf)
    public var indirectPingTimeoutMultiplier: Double = 0.8 {
        willSet {
            precondition(newValue > 0, "Ping timeout multiplier should be > 0")
            precondition(newValue < 1, "Ping timeout multiplier should be < 1")
        }
    }

    /// Suspicion timeouts are specified as number of probe intervals.
    ///
    /// E.g. a `suspicionTimeoutMin = .seconds(3)` means that a suspicious node will be escalated as `.unreachable` at least after approximately 3 seconds.
    /// Suspicion timeout will decay logarithmically from `suspicionTimeoutMax` / with additional suspicions arriving.
    /// When number of suspicions reach `maxIndependentSuspicions`, suspicion timeout will equal `suspicionTimeoutMin`
    ///
    /// ### Modification:
    /// An extra state of "unreachable" is introduced, which is signalled to a high-level membership implementation,
    /// which may then confirm it, then leading the SWIM membership to mark the given member as `.dead`. Unlike the original SWIM/Lifeguard
    /// implementations which proceed to `.dead` automatically. This separation allows running with SWIM failure detection in an "informational"
    /// mode.
    ///
    /// Once it is confirmed dead by the high-level membership (e.g. immediately, or after an additional grace period, or vote),
    /// it will be marked `.dead` in swim, and `.down` in the high-level membership.
    ///
    /// - SeeAlso: [Lifeguard IV.B. Local Health Aware Suspicion (LHA-Suspicion)](https://arxiv.org/pdf/1707.00788.pdf)
    public var suspicionTimeoutMin: Duration = .seconds(3) {
        willSet {
            precondition(newValue.nanoseconds <= self.suspicionTimeoutMax.nanoseconds, "`suspicionTimeoutMin` MUST BE <= `suspicionTimeoutMax`")
        }
    }

    /// A number of independent suspicions required for a suspicion timeout to fully decay to a minimal value.
    ///
    /// When set to 1 will effectively disable LHA-suspicion.
    public var maxIndependentSuspicions = 4 {
        willSet {
            precondition(newValue > 0, "`settings.cluster.swim.maxIndependentSuspicions` MUST BE > 0")
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: SWIM Metrics Settings

/// Configure label names and other details about metrics reported by the `SWIM.Instance`.
public struct SWIMMetricsSettings {
    public init() {}

    /// Configure the segments separator for use when creating labels;
    /// Some systems like graphite like "." as the separator, yet others may not treat this as legal character.
    ///
    /// Typical alternative values are "/" or "_", though consult your metrics backend before changing this setting.
    public var segmentSeparator: String = "."

    /// Prefix all metrics with this segment.
    ///
    /// If set, this is used as the first part of a label name, followed by `labelPrefix`.
    public var systemName: String?

    /// Label string prefixed before all emitted metrics names in their labels.
    ///
    /// - SeeAlso: `systemName`, if set, is prefixed before `labelPrefix` when creating label names.
    public var labelPrefix: String? = "swim"

    func makeLabel(_ segments: String...) -> String {
        let systemNamePart: String = self.systemName.map { "\($0)\(self.segmentSeparator)" } ?? ""
        let systemMetricsPrefixPart: String = self.labelPrefix.map { "\($0)\(self.segmentSeparator)" } ?? ""
        let joinedSegments = segments.joined(separator: self.segmentSeparator)

        return "\(systemNamePart)\(systemMetricsPrefixPart)\(joinedSegments)"
    }
}
