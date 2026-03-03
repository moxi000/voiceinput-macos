import Foundation
import Testing
@testable import VoiceInput

struct SessionControllerTests {
    @Test("旧会话在新会话开始后会被忽略")
    func staleSessionIsIgnoredAfterNewSessionStarts() {
        let controller = SessionController()
        let stale = controller.beginSession()
        let current = controller.beginSession()

        #expect(controller.isCurrent(stale) == false)
        #expect(controller.isCurrent(current))
        #expect(controller.completeSessionIfCurrent(stale) == false)
        #expect(controller.isCurrent(current))
    }

    @Test("watchdog 到期后会收敛并终止当前会话")
    func watchdogTimeoutConvergesSession() {
        let queue = DispatchQueue(label: "session-controller-tests.watchdog")
        let controller = SessionController(finalWatchdogTimeout: 0.02, watchdogQueue: queue)
        let session = controller.beginSession()
        let semaphore = DispatchSemaphore(value: 0)
        var timeoutCount = 0

        controller.armFinalWatchdog(for: session) {
            timeoutCount += 1
            semaphore.signal()
        }

        let waitResult = semaphore.wait(timeout: .now() + 1.0)
        #expect(waitResult == .success)
        #expect(timeoutCount == 1)
        #expect(controller.isCurrent(session) == false)
        #expect(controller.completeSessionIfCurrent(session) == false)
    }

    @Test("旧会话的 watchdog 不应触发")
    func staleSessionWatchdogIsIgnored() {
        let queue = DispatchQueue(label: "session-controller-tests.stale-watchdog")
        let controller = SessionController(finalWatchdogTimeout: 0.01, watchdogQueue: queue)
        let stale = controller.beginSession()
        let current = controller.beginSession()
        let semaphore = DispatchSemaphore(value: 0)

        controller.armFinalWatchdog(for: stale) {
            semaphore.signal()
        }

        let waitResult = semaphore.wait(timeout: .now() + 0.2)
        #expect(waitResult == .timedOut)
        #expect(controller.isCurrent(current))
    }
}
