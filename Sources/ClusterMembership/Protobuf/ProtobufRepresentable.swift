//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Cluster Membership open source project
//
// Copyright (c) 2018-2019 Apple Inc. and the Swift Cluster Membership project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Cluster Membership project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import struct Foundation.Data
import NIO
import protocol Swift.Decoder // to prevent shadowing by the ones in SwiftProtobuf
import protocol Swift.Encoder // to prevent shadowing by the ones in SwiftProtobuf
import SwiftProtobuf

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Protobuf representations

public protocol AnyProtobufRepresentable: Codable {}

public protocol AnyPublicProtobufRepresentable: AnyProtobufRepresentable {}

/// A protocol that facilitates conversion between Swift and protobuf messages.
public protocol ProtobufRepresentable: AnyPublicProtobufRepresentable {
    associatedtype ProtobufRepresentation: SwiftProtobuf.Message

    /// Convert this `ProtobufRepresentable` instance to an instance of type `ProtobufRepresentation`.
    func toProto() throws -> ProtobufRepresentation

    /// Initialize a `ProtobufRepresentable` instance from the given `ProtobufRepresentation` instance.
    init(fromProto proto: ProtobufRepresentation) throws
}

// Implementation note:
// This conformance is a bit weird, and it is not usually going to be invoked through Codable
// however it could, so we allow for this use case.
extension ProtobufRepresentable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        let data: Data = try container.decode(Data.self)
        let proto = try ProtobufRepresentation(serializedData: data)

        try self.init(fromProto: proto)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        let proto = try self.toProto()
        // TODO: Thought; we could detect if we're nested in a top-level JSON that we should encode as json perhaps, since proto can do this?
        let data = try proto.serializedData()

        try container.encode(data)
    }
}

/// This protocol is for internal protobuf-serializable messages only.
///
/// We need a protocol separate from `ProtobufRepresentable` because otherwise we would be forced to make internal types public.
internal protocol InternalProtobufRepresentable: AnyProtobufRepresentable {
    associatedtype ProtobufRepresentation: SwiftProtobuf.Message

    init(from decoder: Decoder) throws
    func encode(to encoder: Encoder) throws

    func toProto() throws -> ProtobufRepresentation
    init(fromProto proto: ProtobufRepresentation) throws
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Errors

// TODO: make a struct for compat
public enum SWIMSerializationError: Error {
    case missingField(String, type: String)
    case missingData(String)
    case unknownEnumValue(Int)
}
