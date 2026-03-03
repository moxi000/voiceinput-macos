import Foundation
import Network
import Testing
@testable import VoiceInput

struct LocalASRTests {
    @Test("握手非 2xx 时应 fail-fast 回调 error")
    func handshakeRejectsNon2xxStatus() async throws {
        let server = try OneShotHTTPServer(response: """
        HTTP/1.1 500 Internal Server Error\r
        Content-Type: text/event-stream\r
        Connection: close\r
        \r
        """)
        defer { server.stop() }

        let callbacks = CallbackState()
        let asr = LocalASR(host: "127.0.0.1", port: server.port)
        asr.onError = { callbacks.appendError($0) }

        asr.startStreaming()
        defer { asr.cancel() }

        let gotRequest = await waitUntil(timeout: 2.0) { !server.requestHeaders.isEmpty }
        #expect(gotRequest)
        let requestHeaders = server.requestHeaders.lowercased()
        #expect(!requestHeaders.contains("transfer-encoding: chunked"))

        let gotError = await waitUntil(timeout: 2.0) { !callbacks.errors().isEmpty }
        #expect(gotError)
        #expect(callbacks.errors().first?.contains("HTTP 状态码") == true)
    }

    @Test("握手 Content-Type 非 text/event-stream 时应 fail-fast 回调 error")
    func handshakeRejectsNonSSEContentType() async throws {
        let server = try OneShotHTTPServer(response: """
        HTTP/1.1 200 OK\r
        Content-Type: application/json\r
        Connection: close\r
        \r
        """)
        defer { server.stop() }

        let callbacks = CallbackState()
        let asr = LocalASR(host: "127.0.0.1", port: server.port)
        asr.onError = { callbacks.appendError($0) }

        asr.startStreaming()
        defer { asr.cancel() }

        let gotError = await waitUntil(timeout: 2.0) { !callbacks.errors().isEmpty }
        #expect(gotError)
        #expect(callbacks.errors().first?.contains("Content-Type") == true)
    }

    @Test("连接完成且无 done 时，若有最后文本则兜底发 final")
    func completeWithoutDoneEmitsFinalWhenTextExists() async throws {
        let server = try OneShotHTTPServer(response: """
        HTTP/1.1 200 OK\r
        Content-Type: text/event-stream; charset=utf-8\r
        Connection: close\r
        \r
        data: {"results":[{"text":"兜底文本"}],"done":false}

        """)
        defer { server.stop() }

        let callbacks = CallbackState()
        let asr = LocalASR(host: "127.0.0.1", port: server.port)
        asr.onFinalResult = { callbacks.appendFinal($0) }
        asr.onError = { callbacks.appendError($0) }

        asr.startStreaming()
        defer { asr.cancel() }

        let gotFinal = await waitUntil(timeout: 2.0) { !callbacks.finals().isEmpty }
        #expect(gotFinal)
        #expect(callbacks.finals().first == "兜底文本")
        #expect(callbacks.errors().isEmpty)
    }

    @Test("连接完成且无 done 时，若无文本则兜底发 error")
    func completeWithoutDoneEmitsErrorWhenTextMissing() async throws {
        let server = try OneShotHTTPServer(response: """
        HTTP/1.1 200 OK\r
        Content-Type: text/event-stream\r
        Connection: close\r
        \r
        """)
        defer { server.stop() }

        let callbacks = CallbackState()
        let asr = LocalASR(host: "127.0.0.1", port: server.port)
        asr.onFinalResult = { callbacks.appendFinal($0) }
        asr.onError = { callbacks.appendError($0) }

        asr.startStreaming()
        defer { asr.cancel() }

        let gotError = await waitUntil(timeout: 2.0) { !callbacks.errors().isEmpty }
        #expect(gotError)
        #expect(callbacks.finals().isEmpty)
        #expect(callbacks.errors().first?.contains("done") == true)
    }
}

private enum OneShotHTTPServerError: Error {
    case startupTimeout
    case missingPort
}

private final class OneShotHTTPServer {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "local.asr.tests.server")
    private let response: String
    private let readySemaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var _port: UInt16?
    private var _requestHeaders = ""

    init(response: String) throws {
        self.listener = try NWListener(using: .tcp, on: .any)
        self.response = response
        configureListener()
        listener.start(queue: queue)

        guard readySemaphore.wait(timeout: .now() + 2.0) == .success else {
            throw OneShotHTTPServerError.startupTimeout
        }
        guard _port != nil else {
            throw OneShotHTTPServerError.missingPort
        }
    }

    var port: UInt16 {
        lock.lock()
        defer { lock.unlock() }
        return _port ?? 0
    }

    var requestHeaders: String {
        lock.lock()
        defer { lock.unlock() }
        return _requestHeaders
    }

    func stop() {
        listener.cancel()
    }

    private func configureListener() {
        listener.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                self.lock.lock()
                self._port = self.listener.port?.rawValue
                self.lock.unlock()
                self.readySemaphore.signal()
            case .failed, .cancelled:
                self.readySemaphore.signal()
            default:
                break
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
    }

    private func handle(_ connection: NWConnection) {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            if case .ready = state {
                self.readRequestHeaders(on: connection, accumulated: Data())
            }
        }
        connection.start(queue: queue)
    }

    private func readRequestHeaders(on connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] content, _, isComplete, error in
            guard let self = self else { return }

            if error != nil {
                connection.cancel()
                return
            }

            var buffer = accumulated
            if let content = content {
                buffer.append(content)
            }

            let separator = Data([0x0D, 0x0A, 0x0D, 0x0A])
            if let range = buffer.range(of: separator) {
                let headerData = buffer[..<range.upperBound]
                let headerText = String(data: headerData, encoding: .utf8) ?? ""
                self.lock.lock()
                self._requestHeaders = headerText
                self.lock.unlock()

                let responseData = Data(self.response.utf8)
                connection.send(
                    content: responseData,
                    contentContext: .defaultMessage,
                    isComplete: true,
                    completion: .contentProcessed { _ in
                        connection.cancel()
                    }
                )
                return
            }

            if isComplete {
                connection.cancel()
                return
            }

            self.readRequestHeaders(on: connection, accumulated: buffer)
        }
    }
}

private final class CallbackState {
    private let lock = NSLock()
    private var errorValues: [String] = []
    private var finalValues: [String] = []

    func appendError(_ value: String) {
        lock.lock()
        errorValues.append(value)
        lock.unlock()
    }

    func appendFinal(_ value: String) {
        lock.lock()
        finalValues.append(value)
        lock.unlock()
    }

    func errors() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return errorValues
    }

    func finals() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return finalValues
    }
}

private func waitUntil(timeout: TimeInterval, pollInterval: TimeInterval = 0.01,
                       condition: @escaping () -> Bool) async -> Bool {
    let sleepNanos = UInt64(pollInterval * 1_000_000_000)
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() {
            return true
        }
        try? await Task.sleep(nanoseconds: sleepNanos)
    }
    return condition()
}
