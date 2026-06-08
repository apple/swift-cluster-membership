//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Cluster Membership open source project
//
// Copyright (c) 2020-2022 Apple Inc. and the Swift Cluster Membership project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of Swift Cluster Membership project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import ClusterMembership

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

extension SWIM.Member: Codable {
    public enum CodingKeys: CodingKey {
        case node
        case status
        case protocolPeriod
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let node = try container.decode(Node.self, forKey: .node)
        let status = try container.decode(SWIM.Status.self, forKey: .status)
        let protocolPeriod = try container.decode(UInt64.self, forKey: .protocolPeriod)
        self.init(node: node, status: status, protocolPeriod: protocolPeriod, suspicionStartedAt: nil)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.node, forKey: .node)
        try container.encode(self.protocolPeriod, forKey: .protocolPeriod)
        try container.encode(self.status, forKey: .status)
    }
}

extension ClusterMembership.Node: Codable {
    // TODO: This implementation has to parse a simplified URI-like representation of a node; need to harden the impl some more
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        // Repr is expected in format: `protocol://host:port#uid`
        let repr = try container.decode(String.self)[...]
        var atIndex = repr.startIndex

        // protocol
        guard let protocolEndIndex = repr.firstIndex(of: ":") else {
            throw SWIMSerializationError.missingField("`protocol`, in \(repr)", type: "String")
        }
        atIndex = protocolEndIndex
        let proto = String(repr[..<atIndex])

        // ://
        atIndex = repr.index(after: atIndex)
        guard repr[repr.index(after: atIndex)] == "/" else {
            throw SWIMSerializationError.missingData("Node format illegal, was: \(repr)")
        }
        atIndex = repr.index(after: atIndex)
        guard repr[repr.index(after: protocolEndIndex)] == "/" else {
            throw SWIMSerializationError.missingData("Node format illegal, was: \(repr)")
        }
        atIndex = repr.index(after: atIndex)

        let name: String?
        if let nameEndIndex = repr[atIndex...].firstIndex(of: "@"), nameEndIndex < repr.endIndex {
            name = String(repr[atIndex..<nameEndIndex])
            atIndex = repr.index(after: nameEndIndex)
        } else {
            name = nil
        }

        // host
        guard let hostEndIndex = repr[atIndex...].firstIndex(of: ":") else {
            throw SWIMSerializationError.missingData("Node format illegal, was: \(repr), failed at `host` part")
        }
        let host = String(repr[atIndex..<hostEndIndex])
        atIndex = hostEndIndex

        // :
        atIndex = repr.index(after: atIndex)
        // port
        let portEndIndex = repr[atIndex...].firstIndex(of: "#") ?? repr.endIndex
        guard let port = Int(String(repr[atIndex..<(portEndIndex)])) else {
            throw SWIMSerializationError.missingData("Node format illegal, missing port, was: \(repr)")
        }

        let uid: UInt64?
        if portEndIndex < repr.endIndex, repr[portEndIndex] == "#" {
            atIndex = repr.index(after: portEndIndex)
            let uidSubString = repr[atIndex..<repr.endIndex]
            if uidSubString.isEmpty {
                uid = nil
            } else {
                uid = UInt64(uidSubString)
            }
        } else {
            uid = nil
        }

        self.init(protocol: proto, name: name, host: host, port: port, uid: uid)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        var repr = "\(self.protocol)://"
        if let name = self.name {
            repr += "\(name)@"
        }
        repr.append("\(self.host):\(self.port)")
        if let uid = self.uid {
            repr.append("#\(uid)")
        }
        try container.encode(repr)
    }
}

extension SWIM.GossipPayload: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let members: [SWIM.Member] = try container.decode([SWIM.Member].self)
        if members.isEmpty {
            self = .none
        } else {
            self = .membership(members)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch self {
        case .none:
            let empty: [SWIM.Member] = []
            try container.encode(empty)

        case .membership(let members):
            try container.encode(members)
        }
    }
}

extension SWIM.Status: Codable {
    public enum DiscriminatorKeys: Int, Codable {
        case alive
        case suspect
        case unreachable
        case dead
    }

    public enum CodingKeys: CodingKey {
        case _status
        case incarnation
        case suspectedBy
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(DiscriminatorKeys.self, forKey: ._status) {
        case .alive:
            let incarnation = try container.decode(SWIM.Incarnation.self, forKey: .incarnation)
            self = .alive(incarnation: incarnation)

        case .suspect:
            let incarnation = try container.decode(SWIM.Incarnation.self, forKey: .incarnation)
            let suspectedBy = try container.decode(Set<Node>.self, forKey: .suspectedBy)
            self = .suspect(incarnation: incarnation, suspectedBy: suspectedBy)

        case .unreachable:
            let incarnation = try container.decode(SWIM.Incarnation.self, forKey: .incarnation)
            self = .unreachable(incarnation: incarnation)

        case .dead:
            self = .dead
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .alive(let incarnation):
            try container.encode(DiscriminatorKeys.alive, forKey: ._status)
            try container.encode(incarnation, forKey: .incarnation)

        case .suspect(let incarnation, let suspectedBy):
            try container.encode(DiscriminatorKeys.suspect, forKey: ._status)
            try container.encode(incarnation, forKey: .incarnation)
            try container.encode(suspectedBy, forKey: .suspectedBy)

        case .unreachable(let incarnation):
            try container.encode(DiscriminatorKeys.unreachable, forKey: ._status)
            try container.encode(incarnation, forKey: .incarnation)

        case .dead:
            try container.encode(DiscriminatorKeys.dead, forKey: ._status)
        }
    }
}

/// Thrown when serialization failed
public enum SWIMSerializationError: Error {
    case notSerializable(String)
    case missingField(String, type: String)
    case missingData(String)
    case unknownEnumValue(Int)
    case __nonExhaustiveAlwaysIncludeADefaultCaseWhenSwitchingOverTheseErrorsPlease
}
