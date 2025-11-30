import Foundation
import SwiftMQ

#if os(Linux)
import Glibc
#else
import Darwin
#endif

private func makeServerSocket(port: UInt16) throws -> Int32 {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }

    var yes: Int32 = 1
    _ = withUnsafePointer(to: &yes) {
        $0.withMemoryRebound(to: Int32.self, capacity: 1) {
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, $0, socklen_t(MemoryLayout<Int32>.size))
        }
    }

    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

    let bindResult = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard bindResult == 0 else {
        let code = errno
        close(fd)
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
    }

    guard listen(fd, 1) == 0 else {
        let code = errno
        close(fd)
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
    }

    return fd
}

private func setNonBlocking(_ fd: Int32) throws {
    let flags = fcntl(fd, F_GETFL)
    guard flags != -1 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    guard fcntl(fd, F_SETFL, flags | O_NONBLOCK) != -1 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
}

private func writeLine(_ string: String, to fd: Int32) {
    let line = string + "\n"
    _ = line.withCString { cStr in
        write(fd, cStr, strlen(cStr))
    }
}

private struct ClientConnection {
    let id: Int
    let fd: Int32
    var receiver: MailboxReceiver
    let shmName: String
    var samples: Int = 0
    var latencyTotalNanos: UInt64 = 0
    var latencyMinNanos: UInt64 = .max
    var latencyMaxNanos: UInt64 = 0
    var latencies: [UInt64] = []
}

private func run() throws {
    let port: UInt16 = 9090
    let serverFD = try makeServerSocket(port: port)
    try setNonBlocking(serverFD)
    print("TestServer: listening on 127.0.0.1:\(port)")

    var nextClientID = 1
    var clients: [ClientConnection] = []

    while true {
        // Accept any pending clients (non-blocking).
        while true {
            var addr = sockaddr()
            var len: socklen_t = socklen_t(MemoryLayout<sockaddr>.size)
            let clientFD = accept(serverFD, &addr, &len)
            if clientFD < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    break
                } else {
                    fputs("TestServer: accept error \(errno)\n", stderr)
                    break
                }
            }

            let clientID = nextClientID
            nextClientID += 1

            let shmName = "smq.cli.\(UUID().uuidString.prefix(8))"
            writeLine(shmName, to: clientFD)
            print("TestServer: [client \(clientID)] connected, shared memory name \(shmName) sent")

            // Retry receiver attach until client creates publisher.
            var receiver: MailboxReceiver?
            for attempt in 1...50 {
                do {
                    receiver = try MailboxReceiver(name: shmName)
                    print("attached receiver after \(attempt) attempts")
                    break
                } catch {
                    usleep(1_000)
                    if attempt == 50 {
                        fputs("TestServer: [client \(clientID)] failed to attach receiver: \(error)\n", stderr)
                    }
                }
            }

            if let rx = receiver {
                clients.append(ClientConnection(id: clientID, fd: clientFD, receiver: rx, shmName: shmName))
            } else {
                close(clientFD)
            }
        }

        // Poll each client serially.
        for idx in clients.indices {
            if let data = clients[idx].receiver.poll() {
                let recv = DispatchTime.now().uptimeNanoseconds
                var sentNanos: UInt64 = 0
                if data.count >= MemoryLayout<UInt64>.size {
                    sentNanos = data.withUnsafeBytes { raw in
                        UInt64(bigEndian: raw.load(as: UInt64.self))
                    }
                    let delta = recv &- sentNanos
                    clients[idx].latencyTotalNanos &+= delta
                    clients[idx].samples += 1
                    clients[idx].latencyMinNanos = min(clients[idx].latencyMinNanos, delta)
                    clients[idx].latencyMaxNanos = max(clients[idx].latencyMaxNanos, delta)
                    clients[idx].latencies.append(delta)
                }
                if clients[idx].samples >= 500 {
                    let avg = Double(clients[idx].latencyTotalNanos) / Double(clients[idx].samples)
                    let avgMicros = avg / 1_000.0
                    let avgMillis = avg / 1_000_000.0
                    let minMicros = Double(clients[idx].latencyMinNanos) / 1_000.0
                    let maxMicros = Double(clients[idx].latencyMaxNanos) / 1_000.0
                    let medianMicros: Double = {
                        let sorted = clients[idx].latencies.sorted()
                        let mid = sorted.count / 2
                        if sorted.count % 2 == 0 {
                            return Double(sorted[mid - 1] + sorted[mid]) / 2_000.0
                        } else {
                            return Double(sorted[mid]) / 1_000.0
                        }
                    }()
                    print(String(format: "TestServer: [client %d] latency over %d samples — avg: %.2f µs (%.3f ms), median: %.2f µs, min: %.2f µs, max: %.2f µs", clients[idx].id, clients[idx].samples, avgMicros, avgMillis, medianMicros, minMicros, maxMicros))
                    close(clients[idx].fd)
                    exit(EXIT_SUCCESS)
                }
            }
        }
    }
}

do {
    try run()
} catch {
    fputs("TestServer error: \(error)\n", stderr)
    exit(EXIT_FAILURE)
}
