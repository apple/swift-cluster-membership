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

import ClusterMembership
import struct Foundation.Data
import NIO
import NIOFoundationCompat
import protocol Swift.Decoder // to prevent shadowing by the ones in SwiftProtobuf
import protocol Swift.Encoder // to prevent shadowing by the ones in SwiftProtobuf
import SwiftProtobuf

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Protobuf representations

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

extension InternalProtobufRepresentable where Self: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        let data: Data = try container.decode(Data.self)
        let proto = try ProtobufRepresentation(serializedData: data)

        try self.init(fromProto: proto)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        let proto = try self.toProto()
        let data = try proto.serializedData()

        try container.encode(data)
    }
}

extension InternalProtobufRepresentable where Self: Codable {
    init(from buffer: inout ByteBuffer) throws {
        guard let data = buffer.readData(length: buffer.readableBytes) else {
            throw SWIMSerializationError.missingData("Unable to read Data from \(buffer)")
        }

        let proto = try ProtobufRepresentation(serializedData: data)
        try self.init(fromProto: proto)
    }

    func serialize(allocator: ByteBufferAllocator) throws -> ByteBuffer {
        let data: Data = try self.toProto().serializedData()
        let buffer = data.withUnsafeBytes { bytes -> ByteBuffer in
            var buffer = allocator.buffer(capacity: data.count)
            buffer.writeBytes(bytes)
            return buffer
        }
        return buffer
    }
}
