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

/// Generic representation of a (potentially unique, if `uid` is present) node in a cluster.
///
/// Generally the node represents "some node we want to contact" if the `uid` is not set,
/// and if the `uid` is available "the specific instance of a node".
public struct Node: Hashable, Sendable, Comparable, CustomStringConvertible {
    /// Protocol that can be used to contact this node;
    /// Does not have to be a formal protocol name and may be "swim" or a name which is understood by a membership implementation.
    public var `protocol`: String
    public var name: String?
    public var host: String
    public var port: Int

    public internal(set) var uid: UInt64?

    public init(protocol: String, host: String, port: Int, uid: UInt64?) {
        self.protocol = `protocol`
        self.name = nil
        self.host = host
        self.port = port
        self.uid = uid
    }

    public init(protocol: String, name: String?, host: String, port: Int, uid: UInt64?) {
        self.protocol = `protocol`
        if let name = name, name.isEmpty {
            self.name = nil
        } else {
            self.name = name
        }
        self.host = host
        self.port = port
        self.uid = uid
    }

    public var withoutUID: Self {
        var without = self
        without.uid = nil
        return without
    }

    public var description: String {
        // /// uid is not printed by default since we only care about it when we do, not in every place where we log a node
        // "\(self.protocol)://\(self.host):\(self.port)"
        self.detailedDescription
    }

    /// Prints a node's String representation including its `uid`.
    public var detailedDescription: String {
        "\(self.protocol)://\(self.name.map { "\($0)@" } ?? "")\(self.host):\(self.port)\(self.uid.map { "#\($0.description)" } ?? "")"
    }
}

public extension Node {
    // Silly but good enough comparison for deciding "who is lower node"
    // as we only use those for "tie-breakers" any ordering is fine to be honest here.
    static func < (lhs: Node, rhs: Node) -> Bool {
        if lhs.protocol == rhs.protocol, lhs.host == rhs.host {
            if lhs.port == rhs.port {
                return (lhs.uid ?? 0) < (rhs.uid ?? 0)
            } else {
                return lhs.port < rhs.port
            }
        } else {
            // "silly" but good enough comparison, we just need a predictable order, does not really matter what it is
            return "\(lhs.protocol)\(lhs.host)" < "\(rhs.protocol)\(rhs.host)"
        }
    }
}
