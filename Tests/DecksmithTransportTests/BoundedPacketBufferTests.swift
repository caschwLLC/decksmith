import XCTest
import Foundation
@testable import DecksmithTransport

final class BoundedPacketBufferTests: XCTestCase {
    func testBufferDropsOldestPacketAtCapacity() async {
        let buffer = BoundedPacketBuffer(capacity: 2)
        await buffer.append(TransportPacket(bytes: Data([1])))
        await buffer.append(TransportPacket(bytes: Data([2])))
        await buffer.append(TransportPacket(bytes: Data([3])))
        let packets = await buffer.drain()
        XCTAssertEqual(packets.map(\.bytes), [Data([2]), Data([3])])
        let metrics = await buffer.snapshotMetrics()
        XCTAssertEqual(metrics.receivedPackets, 3)
        XCTAssertEqual(metrics.droppedPackets, 1)
    }
}
