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

public struct Node: Codable, Hashable {
    public var `protocol`: String
    public var host: String
    public var port: Int
    public var uid: UInt64?

    public init(protocol: String, host: String, port: Int, uid: UInt64?) {
        self.protocol = `protocol`
        self.host = host
        self.port = port
        self.uid = uid
    }
}

extension Node: Comparable {
    // Silly but good enough comparison for deciding "who is lower node"
    // as we only use those for "tie-breakers" any ordering is fine to be honest here.
    public static func < (lhs: Node, rhs: Node) -> Bool {
        if lhs.protocol == rhs.protocol, lhs.host == rhs.host {
            if lhs.port == rhs.port {
                return (lhs.uid ?? 0) < (rhs.uid ?? 0)
            } else {
                return lhs.port < rhs.port
            }
        } else {
            // "silly" but good enough comparison, we just need a predictable order, does not really matter what it is
            return "\(lhs.protocol)\(lhs.host)" < "\(lhs.protocol)\(lhs.host)"
        }
    }
}

// FIXME: would prefer that, but it's hard to express
// public protocol Node: Codable, Hashable {
//    var `protocol`: String { get }
//    var host: String { get }
//    var port: Int { get }
//    var uuid: UInt64? { get }
// }
