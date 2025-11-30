//
//  MailboxPublisher.swift
//  SwiftMQ
//
//  Created by Harlan Haskins on 11/30/25.
//

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

import Synchronization
import System

/// Single-producer side of the mailbox. Writes use a seqlock: flip the sequence to an odd value while writing,
/// then publish the even value to make the update visible to readers.
public final class MailboxPublisher {
    private var mapping: MailboxMapping

    public init(name: String, slots: Int, slotSize: Int) throws {
        self.mapping = try MailboxMapping(
            name: name,
            role: .publisher(slotSize: slotSize, slotCount: slots)
        )
    }

    @usableFromInline
    func reserveSlot(blocking: Bool) -> UInt64? {
        while true {
            let (head, tail) = mapping.producerHeadAndTail
            let used = Int(head &- tail)

            if used < mapping.slotCount {
                return head
            }

            // If we've gotten here, the queue is full (tail == head), so
            // either return nil to indicate that or turn the loop after
            // yielding the thread.

            if !blocking {
                return nil
            }

            sched_yield()
        }
    }

    public var capacity: Int {
        mapping.slotSize
    }

    /// Publish a message using a buffer of bytes.
    @inlinable
    public func publish(_ collection: some Collection<UInt8>, blocking: Bool = false) throws {
        try publish(blocking: blocking) { buf in
            _ = buf.initialize(fromContentsOf: collection)
            return collection.count
        }
    }

    /// Write a message directly into the mailbox's payload buffer.
    /// The closure should return the number of bytes written.
    public func publish(blocking: Bool = false, _ writer: (UnsafeMutableBufferPointer<UInt8>) throws -> Int) throws {
        guard let head = reserveSlot(blocking: blocking) else {
            throw MailboxError.queueFull
        }
        let slotIndex = Int(head % UInt64(mapping.slotCount))
        let offset = MailboxLayout.slotsOffset + slotIndex * mapping.slotStride
        precondition(offset + mapping.slotStride <= mapping.totalSize, "slot write out of bounds")
        let payloadOffset = offset + MemoryLayout<UInt32>.size

        let written: Int = try mapping.shmem.withMutableBuffer(
            ofType: UInt8.self,
            atByteOffset: payloadOffset,
            count: mapping.slotSize
        ) { buffer in
            let bytesWritten = try writer(buffer)
            return bytesWritten
        }

        // This shouldn't happen unless the client is buggy (actually writing to the buffer cannot write more than
        // slotSize).
        guard written <= mapping.slotSize else {
            throw MailboxError.messageTooLarge(capacity: mapping.slotSize, length: written)
        }

        // Write the payload length.

        mapping.shmem.withMutableBuffer(ofType: UInt32.self, atByteOffset: offset, count: 1) { lengthSpan in
            lengthSpan[0] = UInt32(truncatingIfNeeded: written)
        }

        // Move the head forward; the receiver will see this and read the value on its next tick.
        mapping.withHeader { header in
            header.head.store(head &+ 1, ordering: .releasing)
        }
    }
}
