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

import protocol Swift.Decoder // to prevent shadowing by the ones in SwiftProtobuf
import protocol Swift.Encoder // to prevent shadowing by the ones in SwiftProtobuf

extension Node: InternalProtobufRepresentable {
    typealias ProtobufRepresentation = ProtoNode

    func toProto() throws -> ProtobufRepresentation {
        var proto = ProtobufRepresentation()
        proto.protocol = self.protocol
        proto.host = self.host
        proto.port = Int32(self.port)
        if let uid = self.uid {
            proto.uid = UInt64(uid)
        }
        return proto
    }

    init(fromProto proto: ProtobufRepresentation) throws {
        guard !proto.protocol.isEmpty else {
            throw SerializationError.missingField("protocol", type: "String")
        }
        guard !proto.host.isEmpty else {
            throw SerializationError.missingField("host", type: "String")
        }
        guard proto.port > 0 else {
            throw SerializationError.missingField("port", type: "Int")
        }
        guard proto.uid > 0 else {
            throw SerializationError.missingField("port", type: "Int")
        }
        self.protocol = proto.protocol
        self.host = proto.host
        self.port = Int(proto.port)
        self.uid = UInt64(proto.uid)
    }
}
