import Foundation
import Compression

/// Volcengine (火山引擎) 大模型流式语音识别 client — v3 bigmodel protocol.
/// Supports real-time streaming: call startStreaming(), feed chunks via sendAudioChunk(), then endStreaming().
/// Ref: https://www.volcengine.com/docs/6561/1354869
class VolcengineASR: NSObject, ASRService, URLSessionWebSocketDelegate {
    // MARK: - Configuration
    private let appId: String       // X-Api-App-Key
    private let token: String       // X-Api-Access-Key
    private let resourceId: String  // X-Api-Resource-Id

    /// 双向流式优化版 (only sends responses when results change)
    private let endpoint = "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async"

    // MARK: - Protocol constants (v3 bigmodel)
    private let headerByte0: UInt8 = 0x11
    // Message types
    private let msgFullClient: UInt8  = 0b0001
    private let msgAudioOnly: UInt8   = 0b0010
    private let msgServerResp: UInt8  = 0b1001
    private let msgServerError: UInt8 = 0b1111
    // Flags
    private let flagNoSeq: UInt8   = 0b0000
    private let flagPosSeq: UInt8  = 0b0001
    private let flagLast: UInt8    = 0b0010
    private let flagNegSeq: UInt8  = 0b0011
    // Serialization
    private let serialNone: UInt8 = 0b0000
    private let serialJSON: UInt8 = 0b0001
    // Compression
    private let compressNone: UInt8 = 0b0000
    private let compressGzip: UInt8 = 0b0001

    // MARK: - State
    private var webSocket: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var isConnected = false
    private var pendingChunks: [Data] = []
    private var lastReceivedText: String = ""
    private var didEmitFinal = false
    private var confirmedText: String = ""  // accumulated definite utterances

    /// Called with partial transcription text (on main thread)
    var onPartialResult: ((String) -> Void)?
    /// Called with final transcription text (on main thread)
    var onFinalResult: ((String) -> Void)?
    /// Called on error (on main thread)
    var onError: ((String) -> Void)?

    /// Hotwords to boost recognition (max 100). Sent via corpus.context.
    var hotwords: [String] = []

    init(appId: String, token: String, cluster: String) {
        self.appId = appId
        self.token = token
        if cluster.hasPrefix("volc.") {
            self.resourceId = cluster
        } else {
            self.resourceId = "volc.seedasr.sauc.duration"
        }
        super.init()
    }

    // MARK: - Streaming API

    /// Start a streaming session: connect WebSocket and send config.
    func startStreaming() {
        isConnected = false
        pendingChunks = []
        lastReceivedText = ""
        didEmitFinal = false
        confirmedText = ""

        var components = URLComponents(string: endpoint)!
        components.queryItems = [
            URLQueryItem(name: "x-api-app-key", value: appId),
            URLQueryItem(name: "x-api-access-key", value: token),
            URLQueryItem(name: "x-api-resource-id", value: resourceId),
            URLQueryItem(name: "x-api-connect-id", value: UUID().uuidString)
        ]

        guard let url = components.url else {
            emitError("Invalid endpoint URL")
            return
        }

        var request = URLRequest(url: url)
        request.setValue(appId, forHTTPHeaderField: "X-Api-App-Key")
        request.setValue(token, forHTTPHeaderField: "X-Api-Access-Key")
        request.setValue(resourceId, forHTTPHeaderField: "X-Api-Resource-Id")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Api-Connect-Id")

        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        urlSession = URLSession(
            configuration: .default,
            delegate: self,
            delegateQueue: delegateQueue
        )
        webSocket = urlSession!.webSocketTask(with: request)
        webSocket!.resume()

        print("[VolcASR] Connecting...")
    }

    /// Send a chunk of PCM audio data (16kHz, 16-bit, mono). Call this repeatedly during recording.
    func sendAudioChunk(_ pcmData: Data) {
        guard !pcmData.isEmpty else { return }

        if !isConnected {
            // Buffer chunks until WebSocket is ready
            pendingChunks.append(pcmData)
            return
        }

        sendAudioPacket(pcmData, isLast: false)
    }

    /// End the streaming session: send last (empty) packet to signal end of audio.
    func endStreaming() {
        guard isConnected else {
            // Not yet connected — mark that we should end after flushing
            pendingChunks.append(Data())  // empty = sentinel for "last"
            return
        }

        // Send an empty last packet with flagLast
        sendAudioPacket(Data(), isLast: true)
        print("[VolcASR] Sent end-of-stream marker")
    }

    func cancel() {
        isConnected = false
        pendingChunks = []
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
    }

    // MARK: - URLSessionWebSocketDelegate

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        print("[VolcASR] ✅ WebSocket connected")
        isConnected = true

        // 1) Send config
        sendFullClientRequest()

        // 2) Start receiving
        receiveResponses()

        // 3) Flush any buffered chunks
        flushPendingChunks()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        isConnected = false
        let reasonStr = reason.flatMap { String(data: $0, encoding: .utf8) } ?? "none"
        print("[VolcASR] WebSocket closed: code=\(closeCode.rawValue), reason=\(reasonStr)")

        // bigmodel_async closes normally after last definite result
        if closeCode == .normalClosure && !didEmitFinal {
            didEmitFinal = true
            let text = lastReceivedText
            print("[VolcASR] ✅ Final (on close): \"\(text)\"")
            DispatchQueue.main.async { self.onFinalResult?(text) }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        isConnected = false
        if let error = error {
            print("[VolcASR] ❌ Connection error: \(error.localizedDescription)")
            if let httpResp = task.response as? HTTPURLResponse {
                print("[VolcASR] HTTP status: \(httpResp.statusCode)")
            }
            emitError("连接失败: \(error.localizedDescription)")
        }
    }

    // MARK: - Internal: Send

    private func flushPendingChunks() {
        let chunks = pendingChunks
        pendingChunks = []

        for chunk in chunks {
            if chunk.isEmpty {
                // Sentinel: end of stream
                sendAudioPacket(Data(), isLast: true)
                print("[VolcASR] Sent end-of-stream marker (deferred)")
            } else {
                sendAudioPacket(chunk, isLast: false)
            }
        }
    }

    private func sendAudioPacket(_ pcmData: Data, isLast: Bool) {
        let flags: UInt8 = isLast ? flagLast : flagNoSeq

        let payload: Data
        if pcmData.isEmpty {
            payload = Data()
        } else {
            guard let compressed = gzipCompress(pcmData) else { return }
            payload = compressed
        }

        let compression: UInt8 = pcmData.isEmpty ? compressNone : compressGzip

        let msg = buildClientMessage(
            msgType: msgAudioOnly,
            flags: flags,
            serialization: serialNone,
            compression: compression,
            payload: payload
        )

        webSocket?.send(.data(msg)) { error in
            if let error = error {
                print("[VolcASR] Audio send error: \(error.localizedDescription)")
            }
        }
    }

    private func sendFullClientRequest() {
        var config: [String: Any] = [
            "user": [
                "uid": "voiceinput_mac"
            ],
            "audio": [
                "format": "pcm",
                "rate": 16000,
                "bits": 16,
                "channel": 1,
                "codec": "raw"
            ],
            "request": [
                "model_name": "bigmodel",
                "enable_itn": true,
                "enable_punc": true,
                "enable_ddc": false,
                "enable_nonstream": true,
                "result_type": "single",
                "show_utterances": true
            ]
        ]

        // Add hotwords via corpus.context (max 100)
        if !hotwords.isEmpty {
            let words = hotwords.prefix(100).map { ["word": $0] }
            if let jsonData = try? JSONSerialization.data(withJSONObject: ["hotwords": words]),
               let jsonStr = String(data: jsonData, encoding: .utf8) {
                config["corpus"] = ["context": jsonStr]
                print("[VolcASR] Hotwords: \(words.count) words")
            }
        }

        guard let jsonData = try? JSONSerialization.data(withJSONObject: config),
              let compressed = gzipCompress(jsonData) else {
            emitError("JSON序列化失败")
            return
        }

        let msg = buildClientMessage(
            msgType: msgFullClient,
            flags: flagNoSeq,
            serialization: serialJSON,
            compression: compressGzip,
            payload: compressed
        )

        webSocket?.send(.data(msg)) { [weak self] error in
            if let error = error {
                self?.emitError("发送配置失败: \(error.localizedDescription)")
            } else {
                print("[VolcASR] Config sent OK")
            }
        }
    }

    // MARK: - Receive

    private func receiveResponses() {
        webSocket?.receive { [weak self] result in
            guard let self = self else { return }

            switch result {
            case .success(let message):
                switch message {
                case .data(let data):
                    self.parseServerResponse(data)
                case .string(let text):
                    print("[VolcASR] Text: \(text)")
                @unknown default: break
                }
                self.receiveResponses()

            case .failure(let error):
                let msg = error.localizedDescription
                if !msg.contains("cancelled") && !msg.contains("not connected") {
                    print("[VolcASR] Receive error: \(msg)")
                }
            }
        }
    }

    private func parseServerResponse(_ data: Data) {
        guard data.count >= 4 else { return }

        let byte1 = data[1]
        let byte2 = data[2]
        let msgType = byte1 >> 4
        let flags = byte1 & 0x0F
        let compressionType = byte2 & 0x0F

        // Error
        if msgType == msgServerError {
            guard data.count >= 12 else {
                emitError("服务器错误 (数据不完整)")
                return
            }
            let errorCode = data[4..<8].withUnsafeBytes { UInt32(bigEndian: $0.load(as: UInt32.self)) }
            let errorSize = Int(data[8..<12].withUnsafeBytes { UInt32(bigEndian: $0.load(as: UInt32.self)) })
            let errorMsg: String
            if data.count >= 12 + errorSize {
                errorMsg = String(data: data[12..<(12 + errorSize)], encoding: .utf8) ?? "Unknown"
            } else {
                errorMsg = "Unknown"
            }
            print("[VolcASR] ❌ Error: code=\(errorCode), msg=\(errorMsg)")
            emitError("服务器错误 (\(errorCode)): \(errorMsg)")
            return
        }

        // Server response
        guard msgType == msgServerResp else { return }

        var offset = 4

        var sequence: Int32 = 0
        if (flags & 0b0001) != 0 {
            guard data.count >= offset + 4 else { return }
            sequence = data[offset..<(offset+4)].withUnsafeBytes { Int32(bigEndian: $0.load(as: Int32.self)) }
            offset += 4
        }

        let isLast = (flags & 0b0010) != 0
        if flags == flagNegSeq { sequence = -abs(sequence) }

        guard data.count >= offset + 4 else { return }
        let payloadSize = Int(data[offset..<(offset+4)].withUnsafeBytes {
            UInt32(bigEndian: $0.load(as: UInt32.self))
        })
        offset += 4

        guard data.count >= offset + payloadSize else { return }
        let payload = data[offset..<(offset + payloadSize)]

        let jsonData: Data
        if compressionType == compressGzip {
            guard let d = gzipDecompress(Data(payload)) else { return }
            jsonData = d
        } else {
            jsonData = Data(payload)
        }

        guard let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else { return }

        guard let result = json["result"] as? [String: Any] else { return }

        let text = result["text"] as? String ?? ""
        if text.isEmpty { return }

        // Check for definite utterances and accumulate them
        var hasDefinite = false
        if let utterances = result["utterances"] as? [[String: Any]] {
            for u in utterances {
                if u["definite"] as? Bool == true {
                    hasDefinite = true
                    let uText = u["text"] as? String ?? ""
                    if !uText.isEmpty {
                        confirmedText += uText
                    }
                }
            }
        }

        // Build full display text: confirmed sentences + current partial
        let fullText: String
        if hasDefinite {
            fullText = confirmedText
        } else {
            fullText = confirmedText + text
        }

        if isLast || sequence < 0 {
            didEmitFinal = true
            lastReceivedText = fullText
            print("[VolcASR] ✅ Final: \"\(fullText)\"")
            DispatchQueue.main.async { self.onFinalResult?(fullText) }
            webSocket?.cancel(with: .normalClosure, reason: nil)
        } else {
            lastReceivedText = fullText
            print("[VolcASR] \(hasDefinite ? "✓" : "…") \"\(fullText)\"")
            DispatchQueue.main.async { self.onPartialResult?(fullText) }
        }
    }

    // MARK: - Build Client Message

    private func buildClientMessage(
        msgType: UInt8, flags: UInt8,
        serialization: UInt8, compression: UInt8,
        payload: Data
    ) -> Data {
        var msg = Data(capacity: 8 + payload.count)
        msg.append(headerByte0)
        msg.append((msgType << 4) | flags)
        msg.append((serialization << 4) | compression)
        msg.append(0x00)
        var size = UInt32(payload.count).bigEndian
        msg.append(Data(bytes: &size, count: 4))
        msg.append(payload)
        return msg
    }

    // MARK: - Gzip

    private func gzipCompress(_ data: Data) -> Data? {
        guard let deflated = data.withUnsafeBytes({ (srcPtr: UnsafeRawBufferPointer) -> Data? in
            let srcSize = data.count
            let dstSize = srcSize + 512
            let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: dstSize)
            defer { dst.deallocate() }
            let result = compression_encode_buffer(
                dst, dstSize,
                srcPtr.bindMemory(to: UInt8.self).baseAddress!, srcSize,
                nil, COMPRESSION_ZLIB
            )
            guard result > 0 else { return nil }
            return Data(bytes: dst, count: result)
        }) else { return nil }

        var gzip = Data()
        gzip.append(contentsOf: [0x1f, 0x8b, 0x08, 0x00])
        gzip.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
        gzip.append(contentsOf: [0x00, 0x03])
        gzip.append(deflated)
        var crc = crc32Checksum(data)
        gzip.append(Data(bytes: &crc, count: 4))
        var sz = UInt32(data.count)
        gzip.append(Data(bytes: &sz, count: 4))
        return gzip
    }

    private func gzipDecompress(_ data: Data) -> Data? {
        guard data.count > 18 else { return nil }
        var offset = 10
        let flg = data[3]
        if flg & 0x04 != 0 {
            guard data.count > offset + 2 else { return nil }
            let xlen = Int(data[offset]) | (Int(data[offset+1]) << 8)
            offset += 2 + xlen
        }
        if flg & 0x08 != 0 { while offset < data.count && data[offset] != 0 { offset += 1 }; offset += 1 }
        if flg & 0x10 != 0 { while offset < data.count && data[offset] != 0 { offset += 1 }; offset += 1 }
        if flg & 0x02 != 0 { offset += 2 }

        let end = data.count - 8
        guard offset < end else { return nil }
        let deflated = data[offset..<end]

        return deflated.withUnsafeBytes { (srcPtr: UnsafeRawBufferPointer) -> Data? in
            let dstSize = deflated.count * 10 + 4096
            let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: dstSize)
            defer { dst.deallocate() }
            let result = compression_decode_buffer(
                dst, dstSize,
                srcPtr.bindMemory(to: UInt8.self).baseAddress!, deflated.count,
                nil, COMPRESSION_ZLIB
            )
            guard result > 0 else { return nil }
            return Data(bytes: dst, count: result)
        }
    }

    private func crc32Checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        let poly: UInt32 = 0xEDB88320
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc & 1 != 0) ? ((crc >> 1) ^ poly) : (crc >> 1)
            }
        }
        return crc ^ 0xFFFFFFFF
    }

    private func emitError(_ msg: String) {
        print("[VolcASR] ❌ \(msg)")
        DispatchQueue.main.async { self.onError?(msg) }
    }
}
