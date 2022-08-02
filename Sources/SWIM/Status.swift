//===----------------------------------------------------------------------===//
//
// This source file is part of the swift-cluster-membership open source project
//
// Copyright (c) 2018 Apple Inc. and the swift-cluster-membership project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of swift-cluster-membership project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import ClusterMembership

extension SWIM {
    /// The SWIM membership status reflects how a node is perceived by the distributed failure detector.
    ///
    /// ### Modification: Unreachable status (opt-in)
    /// If the unreachable status extension is enabled, it is set / when a classic SWIM implementation would have
    /// declared a node `.dead`, / yet since we allow for the higher level membership to decide when and how to eject
    /// members from a cluster, / only the `.unreachable` state is set and an `Cluster.ReachabilityChange` cluster event
    /// is emitted. / In response to this a high-level membership protocol MAY confirm the node as dead by issuing
    /// `Instance.confirmDead`, / which will promote the node to `.dead` in SWIM terms.
    ///
    /// > The additional `.unreachable` status is only used it enabled explicitly by setting `settings.unreachable`
    /// > to enabled. Otherwise, the implementation performs its failure checking as usual and directly marks detected
    /// > to be failed members as `.dead`.
    ///
    /// ### Legal transitions:
    /// - `alive -> suspect`
    /// - `alive -> suspect`, with next `SWIM.Incarnation`, e.g. during flaky network situations, we suspect and un-suspect a node depending on probing
    /// - `suspect -> unreachable | alive`, if in SWIM terms, a node is "most likely dead" we declare it `.unreachable` instead, and await for high-level confirmation to mark it `.dead`.
    /// - `unreachable -> alive | suspect`, with next `SWIM.Incarnation` optional)
    /// - `alive | suspect | unreachable -> dead`
    ///
    /// - SeeAlso: `SWIM.Incarnation`
    public enum Status: Hashable, Sendable {
        /// Indicates an `alive` member of the cluster, i.e. if is reachable and properly replies to all probes on time.
        case alive(incarnation: Incarnation)
        /// Indicates a `suspect` member of the cluster, meaning that it did not reply on time to probing and MAY be unreachable.
        /// Further probing and indirect probing will be performed to test if it really is unreachable/dead,
        /// or just had a small glitch (or network issues).
        case suspect(incarnation: Incarnation, suspectedBy: Set<Node>)
        /// Extension from traditional SWIM states: indicates an unreachable node, under traditional SWIM it would have
        /// already been marked `.dead`, however unreachability allows for a final extra step including a `swim.confirmDead()`
        /// call, to move the unreachable node to dead state.
        ///
        /// This only matters for multi layer membership protocols which use SWIM as their failure detection mechanism.
        ///
        /// This state is DISABLED BY DEFAULT, and if a node receives such unreachable status about another member while
        /// this setting is disabled it will immediately treat such member as `.dead`. Do not run in mixed mode clusters,
        /// as this can yield unexpected consequences.
        case unreachable(incarnation: Incarnation)
        /// Indicates
        /// Note: In the original paper this state was referred to as "confirm", which we found slightly confusing, thus the rename.
        case dead
    }
}

extension SWIM.Status: Comparable {
    public static func < (lhs: SWIM.Status, rhs: SWIM.Status) -> Bool {
        switch (lhs, rhs) {
        case (.alive(let selfIncarnation), .alive(let rhsIncarnation)):
            return selfIncarnation < rhsIncarnation
        case (.alive(let selfIncarnation), .suspect(let rhsIncarnation, _)):
            return selfIncarnation <= rhsIncarnation
        case (.alive(let selfIncarnation), .unreachable(let rhsIncarnation)):
            return selfIncarnation <= rhsIncarnation
        case (.suspect(let selfIncarnation, let selfSuspectedBy), .suspect(let rhsIncarnation, let rhsSuspectedBy)):
            return selfIncarnation < rhsIncarnation || (selfIncarnation == rhsIncarnation && selfSuspectedBy.isStrictSubset(of: rhsSuspectedBy))
        case (.suspect(let selfIncarnation, _), .alive(let rhsIncarnation)):
            return selfIncarnation < rhsIncarnation
        case (.suspect(let selfIncarnation, _), .unreachable(let rhsIncarnation)):
            return selfIncarnation <= rhsIncarnation
        case (.unreachable(let selfIncarnation), .alive(let rhsIncarnation)):
            return selfIncarnation < rhsIncarnation
        case (.unreachable(let selfIncarnation), .suspect(let rhsIncarnation, _)):
            return selfIncarnation < rhsIncarnation
        case (.unreachable(let selfIncarnation), .unreachable(let rhsIncarnation)):
            return selfIncarnation < rhsIncarnation
        case (.dead, _):
            return false
        case (_, .dead):
            return true
        }
    }
}

extension SWIM.Status {
    /// Only `alive` or `suspect` members carry an incarnation number.
    public var incarnation: SWIM.Incarnation? {
        switch self {
        case .alive(let incarnation):
            return incarnation
        case .suspect(let incarnation, _):
            return incarnation
        case .unreachable(let incarnation):
            return incarnation
        case .dead:
            return nil
        }
    }

    /// - Returns: true if the underlying member status is `.alive`, false otherwise.
    public var isAlive: Bool {
        switch self {
        case .alive:
            return true
        case .suspect, .unreachable, .dead:
            return false
        }
    }

    /// - Returns: true if the underlying member status is `.suspect`, false otherwise.
    public var isSuspect: Bool {
        switch self {
        case .suspect:
            return true
        case .alive, .unreachable, .dead:
            return false
        }
    }

    /// - Returns: true if the underlying member status is `.unreachable`, false otherwise.
    public var isUnreachable: Bool {
        switch self {
        case .unreachable:
            return true
        case .alive, .suspect, .dead:
            return false
        }
    }

    /// - Returns: `true` if the underlying member status is `.unreachable`, false otherwise.
    public var isDead: Bool {
        switch self {
        case .dead:
            return true
        case .alive, .suspect, .unreachable:
            return false
        }
    }

    /// - Returns `true` if `self` is greater than or equal to `other` based on the
    ///   following ordering: `alive(N)` < `suspect(N)` < `alive(N+1)` < `suspect(N+1)` < `dead`
    public func supersedes(_ other: SWIM.Status) -> Bool {
        self >= other
    }
}
