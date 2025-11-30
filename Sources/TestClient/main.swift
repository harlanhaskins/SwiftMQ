import Foundation
import SwiftMQ

#if os(Linux)
import Glibc
#else
import Darwin
#endif

private func connectToServer(host: String, port: UInt16) throws -> Int32 {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }

    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    addr.sin_addr = in_addr(s_addr: inet_addr(host))

    let result = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard result == 0 else {
        let code = errno
        close(fd)
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
    }
    return fd
}

private func readLine(from fd: Int32) throws -> String {
    var buffer = [UInt8](repeating: 0, count: 256)
    var collected = Data()
    while true {
        let n = read(fd, &buffer, buffer.count)
        if n < 0 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        if n == 0 { break }
        collected.append(contentsOf: buffer.prefix(n))
        if collected.last == 10 { // newline
            break
        }
    }
    guard let line = String(data: collected, encoding: .utf8)?
        .trimmingCharacters(in: .newlines), !line.isEmpty else {
        throw NSError(domain: "TestClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Empty handshake"])
    }
    return line
}

private func run() throws {
    let port: UInt16 = 9090
    let fd = try connectToServer(host: "127.0.0.1", port: port)
    print("TestClient: connected to server")

    let shmName = try readLine(from: fd)
    print("TestClient: received mailbox name \(shmName)")

    let publisher = try MailboxPublisher(name: shmName, slots: 4096, slotSize: 64)
    print("TestClient: publisher attached; sending timestamped messages for latency sampling")

    for _ in 0..<500 {
        let now = DispatchTime.now().uptimeNanoseconds
        var big = now.bigEndian
        let data = Data(bytes: &big, count: MemoryLayout<UInt64>.size)
        try publisher.publish(data, blocking: true)
    }

    close(fd)
}

do {
    try run()
} catch {
    fputs("TestClient error: \(error)\n", stderr)
    exit(EXIT_FAILURE)
}
