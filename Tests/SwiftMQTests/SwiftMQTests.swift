import Foundation
import Testing
@testable import SwiftMQ

@Suite struct SwiftMQTests {
    @Test func mailboxRoundTrip() throws {
        let name = "smq.\(UUID().uuidString.prefix(8))"
        let publisher = try MailboxPublisher(name: name, slots: 1024, slotSize: 256)
        let receiver = try MailboxReceiver(name: name)

        let firstMessage = "hello, world".utf8
        try publisher.publish(firstMessage)
        #expect(receiver.poll() == Array(firstMessage))

        // Subsequent poll without a publish should return nil.
        #expect(receiver.poll() == nil)

        let second = [UInt8](repeating: 0xAB, count: 128)
        try publisher.publish(second)
        #expect(receiver.poll() == second)
    }

    @Test func publishWithWriterClosure() throws {
        let name = "smq.\(UUID().uuidString.prefix(8))"
        let publisher = try MailboxPublisher(name: name, slots: 2048, slotSize: 64)
        let receiver = try MailboxReceiver(name: name)

        try publisher.publish(blocking: true) { span in
            let bytes: [UInt8] = Array(0..<32)
            precondition(span.count >= bytes.count)
            for i in 0..<bytes.count {
                span[i] = bytes[i]
            }
            return bytes.count
        }

        let message = receiver.poll()
        #expect(message?.count == 32)
        #expect(message?.first == 0)
        #expect(message?.last == 31)
    }

    @Test func multiMessageQueueOrdering() throws {
        let name = "smq.\(UUID().uuidString.prefix(8))"
        let publisher = try MailboxPublisher(name: name, slots: 512, slotSize: 64)
        let receiver = try MailboxReceiver(name: name)

        let messages = (0..<50).map { "msg-\($0)" }
        for msg in messages {
            try publisher.publish(msg.utf8)
        }

        var received: [String] = []
        var buffer = [UInt8]()
        buffer.reserveCapacity(64)
        while receiver.poll(into: &buffer) {
            received.append(String(decoding: buffer, as: UTF8.self))
        }

        #expect(received == messages)
    }
}
