import Testing
import Foundation
@testable import VoiceInput

struct VolcengineASRParsingTests {
    @Test("Truncated or malformed packets are ignored safely")
    func malformedPacketsDoNotCrashOrMutateState() {
        let asr = makeASR()

        let malformedPackets: [Data] = [
            Data(),
            Data([0x11, 0x90, 0x00]),
            Data([0x11, 0x90, 0x00, 0x00]),
            Data([0x11, 0x91, 0x00, 0x00, 0x00]),
            Data([0x11, 0xF0, 0x00, 0x00, 0x00]),
            Data([0x11, 0xF0, 0x00, 0x00, 0, 0, 0, 1, 0, 0, 0, 0])
        ]

        for packet in malformedPackets {
            asr._test_parseServerResponse(packet)
        }

        #expect(asr._test_lastReceivedText == "")
    }

    @Test("Out-of-bounds payload size is dropped")
    func outOfBoundsPayloadSizeIsDropped() {
        let asr = makeASR()

        var packet = Data([0x11, 0x90, 0x10, 0x00])
        packet.appendUInt32BE(1024)
        packet.append(contentsOf: [0x7B, 0x7D])

        asr._test_parseServerResponse(packet)

        #expect(asr._test_lastReceivedText == "")
    }
}

private func makeASR() -> VolcengineASR {
    VolcengineASR(appId: "test-app", token: "test-token", cluster: "volc.test")
}

private extension Data {
    mutating func appendUInt32BE(_ value: UInt32) {
        append(UInt8((value >> 24) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }
}
