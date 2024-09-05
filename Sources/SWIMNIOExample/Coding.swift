//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Cluster Membership open source project
//
// Copyright (c) 2020-2022 Apple Inc. and the Swift Cluster Membership project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Cluster Membership project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import ClusterMembership
import NIO
import SWIM

import class Foundation.JSONDecoder
import class Foundation.JSONEncoder

typealias SWIMNIODefaultEncoder = JSONEncoder
typealias SWIMNIODefaultDecoder = JSONDecoder

extension CodingUserInfoKey {
    static let channelUserInfoKey = CodingUserInfoKey(rawValue: "nio_peer_channel")!
}

extension SWIM.NIOPeer: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let node = try container.decode(Node.self)
        guard let channel = decoder.userInfo[.channelUserInfoKey] as? Channel else {
            fatalError("Expected channelUserInfoKey to be present in userInfo, unable to decode SWIM.NIOPeer!")
        }
        self.init(node: node, channel: channel)
    }

    public nonisolated func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(self.node)
    }
}


// FIXME: Is it used? Could be a default implementation...
extension ClusterMembership.Node {
    // TODO: This implementation has to parse a simplified URI-like representation of a node; need to harden the impl some more
    public init(repr: String) throws {
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
            name = String(repr[atIndex ..< nameEndIndex])
            atIndex = repr.index(after: nameEndIndex)
        } else {
            name = nil
        }

        // host
        guard let hostEndIndex = repr[atIndex...].firstIndex(of: ":") else {
            throw SWIMSerializationError.missingData("Node format illegal, was: \(repr), failed at `host` part")
        }
        let host = String(repr[atIndex ..< hostEndIndex])
        atIndex = hostEndIndex

        // :
        atIndex = repr.index(after: atIndex)
        // port
        let portEndIndex = repr[atIndex...].firstIndex(of: "#") ?? repr.endIndex
        guard let port = Int(String(repr[atIndex ..< (portEndIndex)])) else {
            throw SWIMSerializationError.missingData("Node format illegal, missing port, was: \(repr)")
        }

        let uid: UInt64?
        if portEndIndex < repr.endIndex, repr[portEndIndex] == "#" {
            atIndex = repr.index(after: portEndIndex)
            let uidSubString = repr[atIndex ..< repr.endIndex]
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

/// Thrown when serialization failed
public enum SWIMSerializationError: Error {
    case notSerializable(String)
    case missingField(String, type: String)
    case missingData(String)
    case unknownEnumValue(Int)
    case __nonExhaustiveAlwaysIncludeADefaultCaseWhenSwitchingOverTheseErrorsPlease
}
