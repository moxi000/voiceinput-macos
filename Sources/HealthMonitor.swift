import Foundation

struct HealthSnapshot: Equatable {
    let requestCount: Int
    let averageLatencyMs: Double
    let failureRate: Double
    let fallbackRate: Double
    let recentErrorReason: String?
}

enum HealthMonitor {
    private static let lock = NSLock()
    private static var requestCount = 0
    private static var totalLatencySeconds: TimeInterval = 0
    private static var failureCount = 0
    private static var fallbackCount = 0
    private static var recentErrorReason: String?

    static func record(latency: TimeInterval, failed: Bool, fallbackUsed: Bool, errorReason: String?) {
        lock.lock()
        defer { lock.unlock() }

        requestCount += 1
        totalLatencySeconds += latency
        if failed {
            failureCount += 1
        }
        if fallbackUsed {
            fallbackCount += 1
        }
        if let errorReason, !errorReason.isEmpty {
            recentErrorReason = errorReason
        }
    }

    static func snapshot() -> HealthSnapshot {
        lock.lock()
        defer { lock.unlock() }

        guard requestCount > 0 else {
            return HealthSnapshot(
                requestCount: 0,
                averageLatencyMs: 0,
                failureRate: 0,
                fallbackRate: 0,
                recentErrorReason: nil
            )
        }

        let averageMs = (totalLatencySeconds / Double(requestCount)) * 1000
        let failureRate = Double(failureCount) / Double(requestCount)
        let fallbackRate = Double(fallbackCount) / Double(requestCount)

        return HealthSnapshot(
            requestCount: requestCount,
            averageLatencyMs: averageMs,
            failureRate: failureRate,
            fallbackRate: fallbackRate,
            recentErrorReason: recentErrorReason
        )
    }

    static func reset() {
        lock.lock()
        defer { lock.unlock() }

        requestCount = 0
        totalLatencySeconds = 0
        failureCount = 0
        fallbackCount = 0
        recentErrorReason = nil
    }
}
