//
//  MailboxReceiver.swift
//  SwiftMQ
//
//  Created by Harlan Haskins on 11/30/25.
//

/// Single-consumer side of the mailbox. Polling uses the seqlock to avoid torn reads.
public final class MailboxReceiver {
    private var mapping: MailboxMapping

    public init(name: String) throws {
        self.mapping = try MailboxMapping(name: name, role: .receiver)
    }

    public var capacity: Int {
        mapping.slotSize
    }

    /// Returns the next message, or nil if the publisher has not advanced the sequence number.
    public func poll() -> [UInt8]? {
        var result = [UInt8]()
        result.reserveCapacity(mapping.slotStride)
        guard poll(into: &result) else { return nil }
        return result
    }

    /// Poll into a pre-allocated `[UInt8]` buffer to avoid additional allocations.
    /// Returns true when a fresh message was read.
    @discardableResult
    public func poll(into buffer: inout [UInt8]) -> Bool {
        poll { payloadSpan in
            buffer.removeAll(keepingCapacity: true)
            buffer.append(contentsOf: payloadSpan)
        }
    }

    /// Poll with direct read access to the underlying buffer pointer, avoiding copies.
    /// The reader closure receives an `UnsafeBufferPointer<UInt8>` with the message payload.
    /// Returns true when a fresh message was read.
    @discardableResult
    public func poll(_ reader: (UnsafeBufferPointer<UInt8>) throws -> Void) rethrows -> Bool {
        let (head, tail) = mapping.consumerHeadAndTail
        if tail == head {
            return false
        }

        let slotIndex = Int(tail % UInt64(mapping.slotCount))
        let offset = MailboxLayout.slotsOffset + slotIndex * mapping.slotStride
        precondition(offset + mapping.slotStride <= mapping.totalSize, "slot read out of bounds")

        // First, read the payload length from the slot.
        let length = Int(mapping.shmem.load(fromByteOffset: offset, as: UInt32.self))

        // Make sure the length is within bounds.
        guard length <= mapping.slotSize else { return false }

        // Give the reader direct access to the payload buffer.
        if length > 0 {
            let payloadOffset = offset + MemoryLayout<UInt32>.size
            try mapping.shmem.withBuffer(ofType: UInt8.self, atByteOffset: payloadOffset, count: length) { payloadSpan in
                try reader(payloadSpan)
            }
        } else {
            try reader(UnsafeBufferPointer(start: nil, count: 0))
        }

        // Once we've read the full payload, atomically update the tail to free it in the publisher.
        mapping.withHeader { header in
            header.tail.store(tail &+ 1, ordering: .releasing)
        }

        return true
    }
}
