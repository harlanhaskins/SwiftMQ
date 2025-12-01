//
//  SharedMemory.swift
//  SwiftMQ
//
//  Created by Harlan Haskins on 11/30/25.
//

private import CSwiftMQShims
import System

struct SharedMemory: ~Copyable {
    let fileDescriptor: FileDescriptor
    private let buffer: UnsafeMutableRawBufferPointer
    private var isClosed: Bool = false
    private var isOwned: Bool = false

    init(forWritingTo name: String, capacity: Int) throws {
        let descriptor = swiftmq_shm_open(
            name,
            O_CREAT | O_EXCL | O_RDWR,
            mode_t(S_IRUSR | S_IWUSR | S_IRGRP | S_IWGRP)
        )
        guard descriptor >= 0 else {
            throw MailboxError.openFailed(errno: errno)
        }

        let fileDescriptor = FileDescriptor(rawValue: descriptor)
        let buffer: UnsafeMutableRawBufferPointer
        do {
            if ftruncate(descriptor, off_t(capacity)) != 0 {
                throw MailboxError.truncateFailed(errno: errno)
            }
            buffer = try SharedMemory.createMemoryMap(fileDescriptor, size: capacity)
        } catch {
            try fileDescriptor.close()
            throw error
        }

        self.isOwned = true
        self.fileDescriptor = fileDescriptor
        self.buffer = buffer
    }

    init(forReadingFrom name: String) throws {
        let descriptor = swiftmq_shm_open(
            name,
            O_RDWR,
            mode_t(S_IRUSR | S_IWUSR | S_IRGRP | S_IWGRP)
        )
        guard descriptor >= 0 else {
            throw MailboxError.openFailed(errno: errno)
        }

        let fileDescriptor = FileDescriptor(rawValue: descriptor)
        do {
            var statBuffer = stat()
            guard fstat(descriptor, &statBuffer) == 0 else {
                throw MailboxError.statFailed(errno: errno)
            }

            self.buffer = try SharedMemory.createMemoryMap(fileDescriptor, size: Int(statBuffer.st_size))
        } catch {
            try fileDescriptor.close()
            throw error
        }
        self.fileDescriptor = fileDescriptor
        self.isOwned = false
    }

    static func createMemoryMap(_ descriptor: FileDescriptor, size: Int) throws -> UnsafeMutableRawBufferPointer {
        let protection: Int32 = PROT_READ | PROT_WRITE
        let mapping = mmap(nil, size, protection, MAP_SHARED, descriptor.rawValue, 0)
        guard mapping != MAP_FAILED, let mapping else {
            throw MailboxError.mapFailed(errno: errno)
        }
        return UnsafeMutableRawBufferPointer(start: mapping, count: size)
    }

    @_transparent
    func load<T: BitwiseCopyable>(fromByteOffset offset: Int = 0, as type: T.Type) -> T {
        buffer.baseAddress!.loadUnaligned(fromByteOffset: offset, as: T.self)
    }

    @_transparent
    func withBytes<Result, E: Error>(
        atByteOffset offset: Int = 0,
        count: Int,
        perform: (UnsafeRawBufferPointer) throws(E) -> Result
    ) throws(E) -> Result {
        let ptr = buffer.baseAddress!.advanced(by: offset)
        return try perform(UnsafeRawBufferPointer(start: ptr, count: count))
    }

    @_transparent
    func withBuffer<T: ~Copyable, Result, E: Error>(
        ofType: T.Type = T.self,
        atByteOffset offset: Int = 0,
        count: Int,
        perform: (UnsafeBufferPointer<T>) throws(E) -> Result
    ) throws(E) -> Result {
        let ptr = buffer.baseAddress!.advanced(by: offset).assumingMemoryBound(to: T.self)
        return try perform(UnsafeBufferPointer(start: ptr, count: count))
    }

    @_transparent
    func withMutableBuffer<T: ~Copyable, Result, E: Error>(
        ofType: T.Type = T.self,
        atByteOffset offset: Int = 0,
        count: Int,
        perform: (UnsafeMutableBufferPointer<T>) throws(E) -> Result
    ) throws(E) -> Result {
        let ptr = buffer.baseAddress!.advanced(by: offset).assumingMemoryBound(to: T.self)
        return try perform(UnsafeMutableBufferPointer(start: ptr, count: count))
    }

    private func closeIfNeeded() {
        if isClosed {
            return
        }
        try? fileDescriptor.close()
        if isOwned {
            shm_unlink(buffer.baseAddress!)
        }
    }

    consuming func close() {
        closeIfNeeded()
        isClosed = true
    }

    deinit {
        closeIfNeeded()
    }
}
