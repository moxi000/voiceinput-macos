import Foundation
import Network

/// Local ASR service using a raw TCP connection to a local server.
/// Protocol: HTTP chunked POST with length-prefixed audio frames, SSE response stream with JSON events.
class LocalASR: ASRService {
    private let host: String
    private let port: UInt16

    private var connection: NWConnection?
    private var isConnected = false
    private var pendingChunks: [Data] = []
    private var responseBuffer = Data()
    private var didEmitFinal = false

    var onPartialResult: ((String) -> Void)?
    var onFinalResult: ((String) -> Void)?
    var onError: ((String) -> Void)?

    init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }

    // MARK: - ASRService

    func startStreaming() {
        isConnected = false
        pendingChunks = []
        responseBuffer = Data()
        didEmitFinal = false

        let nwHost = NWEndpoint.Host(host)
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            emitError("无效端口: \(port)")
            return
        }
        connection = NWConnection(host: nwHost, port: nwPort, using: .tcp)

        connection?.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.isConnected = true
                print("[LocalASR] Connected to \(self?.host ?? ""):\(self?.port ?? 0)")
                self?.sendHTTPHandshake()
                self?.readResponseHeaders()
            case .failed(let error):
                print("[LocalASR] Connection failed: \(error)")
                self?.emitError("连接失败: \(error.localizedDescription)")
            case .cancelled:
                print("[LocalASR] Connection cancelled")
            default:
                break
            }
        }

        connection?.start(queue: .global(qos: .userInitiated))
        print("[LocalASR] Connecting to \(host):\(port)...")
    }

    func sendAudioChunk(_ pcmData: Data) {
        guard !pcmData.isEmpty else { return }

        if !isConnected {
            pendingChunks.append(pcmData)
            return
        }

        sendAudioFrame(pcmData)
    }

    func endStreaming() {
        guard isConnected else {
            pendingChunks.append(Data())  // sentinel for end-of-stream
            return
        }

        sendEndFrame()
        print("[LocalASR] Sent end-of-stream marker")
    }

    func cancel() {
        isConnected = false
        pendingChunks = []
        connection?.cancel()
        connection = nil
    }

    // MARK: - HTTP Handshake

    private func sendHTTPHandshake() {
        let request = "POST /asr/realtime HTTP/1.1\r\n"
            + "Host: \(host):\(port)\r\n"
            + "Content-Type: application/octet-stream\r\n"
            + "Transfer-Encoding: chunked\r\n"
            + "Connection: keep-alive\r\n"
            + "\r\n"

        guard let data = request.data(using: .utf8) else { return }
        connection?.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error = error {
                self?.emitError("握手发送失败: \(error.localizedDescription)")
            } else {
                print("[LocalASR] HTTP handshake sent")
                self?.flushPendingChunks()
            }
        })
    }

    // MARK: - Read Response Headers then SSE

    private func readResponseHeaders() {
        readUntilHeaderEnd(accumulated: Data())
    }

    private func readUntilHeaderEnd(accumulated: Data) {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 4096) {
            [weak self] content, _, isComplete, error in
            guard let self = self else { return }

            if let error = error {
                self.emitError("读取响应失败: \(error.localizedDescription)")
                return
            }

            var buffer = accumulated
            if let content = content {
                buffer.append(content)
            }

            let separator = Data([0x0D, 0x0A, 0x0D, 0x0A])  // \r\n\r\n
            if let headerEndRange = buffer.range(of: separator) {
                // Headers complete
                let bodyStart = headerEndRange.upperBound
                if bodyStart < buffer.count {
                    let initialBody = buffer[bodyStart...]
                    self.responseBuffer.append(contentsOf: initialBody)
                    self.processSSEBuffer()
                }

                // Log status line
                let headerData = buffer[buffer.startIndex..<headerEndRange.lowerBound]
                if let headerStr = String(data: headerData, encoding: .utf8) {
                    let firstLine = headerStr.components(separatedBy: "\r\n").first ?? ""
                    print("[LocalASR] Response: \(firstLine)")
                }

                // Start continuous SSE reading
                self.readSSEData()
            } else if isComplete {
                self.emitError("连接关闭，未收到完整响应头")
            } else {
                self.readUntilHeaderEnd(accumulated: buffer)
            }
        }
    }

    // MARK: - SSE Reading

    private func readSSEData() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
            [weak self] content, _, isComplete, error in
            guard let self = self else { return }

            if let error = error {
                if !self.didEmitFinal {
                    self.emitError("SSE读取错误: \(error.localizedDescription)")
                }
                return
            }

            if let content = content {
                self.responseBuffer.append(content)
                self.processSSEBuffer()
            }

            if isComplete {
                if !self.didEmitFinal {
                    self.didEmitFinal = true
                    print("[LocalASR] Connection completed without explicit done signal")
                }
                return
            }

            if !self.didEmitFinal {
                self.readSSEData()
            }
        }
    }

    private func processSSEBuffer() {
        guard let str = String(data: responseBuffer, encoding: .utf8) else { return }

        let lines = str.components(separatedBy: "\n")

        // Keep the last incomplete line in the buffer
        if str.hasSuffix("\n") {
            responseBuffer = Data()
        } else {
            let lastLine = lines.last ?? ""
            responseBuffer = lastLine.data(using: .utf8) ?? Data()
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("data: ") else { continue }

            let jsonStr = String(trimmed.dropFirst(6))
            guard let jsonData = jsonStr.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
            else { continue }

            handleSSEEvent(json)
        }
    }

    private func handleSSEEvent(_ json: [String: Any]) {
        // Skip status/ready events
        if json["status"] as? String == "ready" { return }

        let isDone = json["done"] as? Bool ?? false

        // Extract text from results array:
        // results[last].text is the merged transcript
        let text: String
        if let results = json["results"] as? [[String: Any]], let last = results.last {
            text = last["text"] as? String ?? ""
        } else {
            text = json["text"] as? String ?? ""
        }

        if isDone {
            guard !didEmitFinal else { return }
            didEmitFinal = true
            print("[LocalASR] Final: \"\(text)\"")
            DispatchQueue.main.async { self.onFinalResult?(text) }
            connection?.cancel()
        } else if !text.isEmpty {
            print("[LocalASR] Partial: \"\(text)\"")
            DispatchQueue.main.async { self.onPartialResult?(text) }
        }
    }

    // MARK: - Send Audio Frames

    private func flushPendingChunks() {
        let chunks = pendingChunks
        pendingChunks = []

        for chunk in chunks {
            if chunk.isEmpty {
                sendEndFrame()
                print("[LocalASR] Sent end-of-stream marker (deferred)")
            } else {
                sendAudioFrame(chunk)
            }
        }
    }

    private func sendAudioFrame(_ pcmData: Data) {
        // Length-prefixed frame: 4-byte big-endian uint32 length + PCM data
        var length = UInt32(pcmData.count).bigEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(pcmData)

        connection?.send(content: frame, completion: .contentProcessed { error in
            if let error = error {
                print("[LocalASR] Audio send error: \(error.localizedDescription)")
            }
        })
    }

    private func sendEndFrame() {
        // Zero-length frame: 4 bytes of zeros
        let frame = Data(count: 4)
        connection?.send(content: frame, completion: .contentProcessed { error in
            if let error = error {
                print("[LocalASR] End frame send error: \(error.localizedDescription)")
            }
        })
    }

    // MARK: - Helpers

    private func emitError(_ msg: String) {
        print("[LocalASR] Error: \(msg)")
        DispatchQueue.main.async { self.onError?(msg) }
    }
}
