//
//  MailboxMapping.swift
//  SwiftMQ
//
//  Created by Harlan Haskins on 11/30/25.
//

// Internal mapping around the shared memory region.
final class MailboxMapping {
    let name: String
    let slotSize: Int
    let slotCount: Int
    let totalSize: Int

    var shmem: SharedMemory

    let slotStride: Int

    init(
        name: String,
        role: MailboxRole
    ) throws {
        let canonical = MailboxLayout.canonicalName(name)
        guard canonical.utf8.count <= MailboxLayout.maxNameLength else {
            throw MailboxError.nameTooLong(max: MailboxLayout.maxNameLength)
        }

        switch role {
        case .publisher(let size, let count):
            let totalSize = MailboxLayout.totalSize(slotCount: count, slotSize: size)
            shmem = try SharedMemory(forWritingTo: name, capacity: totalSize)
            shmem.withMutableBuffer(ofType: MailboxLayout.Header.self, count: 1) { buffer in
                buffer[0] = MailboxLayout.Header(slotCount: count, slotSize: size)
            }

            slotCount = count
            slotSize = size
        case .receiver:
            shmem = try SharedMemory(forReadingFrom: name)

            let (discoveredCount, discoveredCapacity) = shmem.withMutableBuffer(
                ofType: MailboxLayout.Header.self,
                count: 1
            ) { header in
                (Int(header[0].slotCount), Int(header[0].slotSize))
            }

            guard discoveredCount > 0, discoveredCapacity > 0 else {
                throw MailboxError.corruptLayout
            }
            slotCount = discoveredCount
            slotSize = discoveredCapacity
        }

        slotStride = MailboxLayout.slotStride(slotSize: slotSize)
        totalSize = MailboxLayout.totalSize(slotCount: slotCount, slotSize: slotSize)
        self.name = canonical
    }

    func withHeader(_ update: (inout MailboxLayout.Header) -> Void) {
        shmem.withMutableBuffer(
            ofType: MailboxLayout.Header.self,
            count: 1
        ) { headerBuffer in
            update(&headerBuffer[0])
        }
    }

    /// For producer fast-path: head relaxed, tail acquire (tail is stored with release).
    var producerHeadAndTail: (UInt64, UInt64) {
        shmem.withMutableBuffer(
            ofType: MailboxLayout.Header.self,
            count: 1
        ) { header in
            let head = header[0].head.load(ordering: .relaxed)
            let tail = header[0].tail.load(ordering: .acquiring)
            return (head, tail)
        }
    }

    /// For consumer: head acquire (to see payload/length before head), tail relaxed.
    var consumerHeadAndTail: (UInt64, UInt64) {
        shmem.withMutableBuffer(
            ofType: MailboxLayout.Header.self,
            count: 1
        ) { header in
            let head = header[0].head.load(ordering: .acquiring)
            let tail = header[0].tail.load(ordering: .relaxed)
            return (head, tail)
        }
    }
}
