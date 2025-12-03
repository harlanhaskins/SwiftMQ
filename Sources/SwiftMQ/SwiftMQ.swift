import Atomics
import Foundation
import Synchronization

/// Errors that can be raised while working with a shared mailbox.
public enum MailboxError: Error, CustomStringConvertible {
    case invalidCapacity
    case queueFull
    case nameTooLong(max: Int)
    case openFailed(errno: Int32)
    case truncateFailed(errno: Int32)
    case statFailed(errno: Int32)
    case mapFailed(errno: Int32)
    case corruptLayout
    case messageTooLarge(capacity: Int, length: Int)
    case closed

    public var description: String {
        switch self {
        case .invalidCapacity:
            return "Requested payload capacity must be positive."
        case .queueFull:
            return "Mailbox queue is full."
        case .nameTooLong(let max):
            return "Mailbox name exceeds maximum length of \(max) bytes."
        case .openFailed(let err):
            return "shm_open failed with errno \(err)."
        case .truncateFailed(let err):
            return "ftruncate failed with errno \(err)."
        case .statFailed(let err):
            return "fstat failed with errno \(err)."
        case .mapFailed(let err):
            return "mmap failed with errno \(err)."
        case .corruptLayout:
            return "Shared memory layout is smaller than expected."
        case .messageTooLarge(let capacity, let length):
            return "Payload of \(length) bytes exceeds mailbox capacity of \(capacity) bytes."
        case .closed:
            return "Mailbox was closed."
        }
    }
}

enum MailboxRole {
    case publisher(slotSize: Int, slotCount: Int)
    case receiver
}

enum MailboxLayout {
    struct Header: ~Copyable {
        let head: Atomic<UInt64>
        let tail: Atomic<UInt64>
        var slotCount: UInt32
        var slotSize: UInt32

        init(slotCount: Int, slotSize: Int) {
            self.head = Atomic(0)
            self.tail = Atomic(0)
            self.slotCount = UInt32(slotCount)
            self.slotSize = UInt32(slotSize)
        }
    }

    static let headerSize = MemoryLayout<Header>.stride
    static let maxNameLength = 30 // POSIX shared memory name limit (excluding null terminator)

    static var slotsOffset: Int { headerSize }

    static func slotStride(slotSize: Int) -> Int {
        let raw = MemoryLayout<UInt32>.stride + slotSize
        let align = MemoryLayout<UInt64>.alignment
        return (raw + (align - 1)) / align * align
    }

    static func totalSize(slotCount: Int, slotSize: Int) -> Int {
        headerSize + slotCount * slotStride(slotSize: slotSize)
    }
}
