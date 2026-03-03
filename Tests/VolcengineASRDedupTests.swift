import Testing
import Foundation
@testable import VoiceInput

struct VolcengineASRDedupTests {
    @Test("Definite utterance with same id is appended only once")
    func definiteUtteranceWithSameIDIsDeduplicated() throws {
        let asr = makeASRForDedupTest()

        let response: [String: Any] = [
            "text": "你好",
            "utterances": [
                [
                    "id": "utt-1",
                    "definite": true,
                    "text": "你好"
                ]
            ]
        ]

        let packet = try makeServerResponsePacket(result: response)
        asr._test_parseServerResponse(packet)
        #expect(asr._test_confirmedText == "你好")

        asr._test_parseServerResponse(packet)
        #expect(asr._test_confirmedText == "你好")
        #expect(asr._test_lastReceivedText == "你好")
    }

    @Test("Definite utterance without id is deduplicated by text")
    func definiteUtteranceWithoutIDIsDeduplicatedByText() throws {
        let asr = makeASRForDedupTest()

        let response: [String: Any] = [
            "text": "世界",
            "utterances": [
                [
                    "definite": true,
                    "text": "世界"
                ]
            ]
        ]

        let packet = try makeServerResponsePacket(result: response)
        asr._test_parseServerResponse(packet)
        #expect(asr._test_confirmedText == "世界")

        asr._test_parseServerResponse(packet)
        #expect(asr._test_confirmedText == "世界")
        #expect(asr._test_lastReceivedText == "世界")
    }
}

private func makeASRForDedupTest() -> VolcengineASR {
    VolcengineASR(appId: "test-app", token: "test-token", cluster: "volc.test")
}

private func makeServerResponsePacket(result: [String: Any]) throws -> Data {
    let payload = try JSONSerialization.data(withJSONObject: ["result": result], options: [])

    var packet = Data([0x11, 0x90, 0x10, 0x00])
    packet.appendUInt32BE(UInt32(payload.count))
    packet.append(payload)
    return packet
}

private extension Data {
    mutating func appendUInt32BE(_ value: UInt32) {
        append(UInt8((value >> 24) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }
}
