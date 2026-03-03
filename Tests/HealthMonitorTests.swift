import Testing
@testable import VoiceInput

struct HealthMonitorTests {
    @Test("reset 后指标归零")
    func resetClearsAllStats() {
        HealthMonitor.record(latency: 0.2, failed: true, fallbackUsed: true, errorReason: "HTTP 500")
        HealthMonitor.reset()

        let snapshot = HealthMonitor.snapshot()
        #expect(snapshot.requestCount == 0)
        #expect(snapshot.averageLatencyMs == 0)
        #expect(snapshot.failureRate == 0)
        #expect(snapshot.fallbackRate == 0)
        #expect(snapshot.recentErrorReason == nil)
    }

    @Test("记录成功和失败后可计算延迟/失败率/回退率")
    func recordsMetrics() {
        HealthMonitor.reset()

        HealthMonitor.record(latency: 0.1, failed: false, fallbackUsed: false, errorReason: nil)
        HealthMonitor.record(latency: 0.3, failed: true, fallbackUsed: true, errorReason: "HTTP 429")

        let snapshot = HealthMonitor.snapshot()
        #expect(snapshot.requestCount == 2)
        #expect(abs(snapshot.averageLatencyMs - 200) < 0.001)
        #expect(abs(snapshot.failureRate - 0.5) < 0.0001)
        #expect(abs(snapshot.fallbackRate - 0.5) < 0.0001)
        #expect(snapshot.recentErrorReason == "HTTP 429")
    }
}
