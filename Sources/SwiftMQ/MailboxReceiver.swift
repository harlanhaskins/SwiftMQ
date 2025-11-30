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
        let (head, tail) = mapping.consumerHeadAndTail
        if tail == head {
            return false
        }

        let slotIndex = Int(tail % UInt64(mapping.slotCount))
        let offset = MailboxLayout.slotsOffset + slotIndex * mapping.slotStride
        precondition(offset + mapping.slotStride <= mapping.totalSize, "slot read out of bounds")

        // First, read the payload from the slot.

        let length = mapping.shmem.withBuffer(ofType: UInt32.self, atByteOffset: offset, count: 1) { lengthSpan in
            Int(lengthSpan[0])
        }

        // Make sure the length is within bounds.
        guard length <= mapping.slotSize else { return false }

        // Clear the buffer and then read the contents of the payload into it.

        buffer.removeAll(keepingCapacity: true)
        if length > 0 {
            let payloadOffset = offset + MemoryLayout<UInt32>.size
            mapping.shmem.withBuffer(ofType: UInt8.self, atByteOffset: payloadOffset, count: length) { payloadSpan in
                for i in 0..<length {
                    buffer.append(payloadSpan[i])
                }
            }
        }

        // Once we've read the full payload, atomically update the tail to free it in the publisher.
        mapping.withHeader { header in
            header.tail.store(tail &+ 1, ordering: .releasing)
        }

        return true
    }
}
