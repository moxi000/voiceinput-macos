import Foundation

/// Coordinates the currently active recording session and its final-result timeout watchdog.
final class SessionController {
    typealias SessionID = UUID

    private let stateQueue = DispatchQueue(label: "voiceinput.session.controller")
    private let watchdogQueue: DispatchQueue

    private var currentSessionID: SessionID?
    private var watchdogWorkItem: DispatchWorkItem?
    private var watchdogTimeoutSeconds: TimeInterval

    init(finalWatchdogTimeout: TimeInterval = 10.0, watchdogQueue: DispatchQueue = .main) {
        self.watchdogQueue = watchdogQueue
        self.watchdogTimeoutSeconds = max(0, finalWatchdogTimeout)
    }

    var finalWatchdogTimeout: TimeInterval {
        get {
            stateQueue.sync { watchdogTimeoutSeconds }
        }
        set {
            stateQueue.sync { watchdogTimeoutSeconds = max(0, newValue) }
        }
    }

    @discardableResult
    func beginSession() -> SessionID {
        stateQueue.sync {
            cancelWatchdogLocked()
            let next = SessionID()
            currentSessionID = next
            return next
        }
    }

    func isCurrent(_ sessionID: SessionID) -> Bool {
        stateQueue.sync { currentSessionID == sessionID }
    }

    func currentSession() -> SessionID? {
        stateQueue.sync { currentSessionID }
    }

    @discardableResult
    func completeSessionIfCurrent(_ sessionID: SessionID) -> Bool {
        stateQueue.sync {
            guard currentSessionID == sessionID else { return false }
            currentSessionID = nil
            cancelWatchdogLocked()
            return true
        }
    }

    func armFinalWatchdog(for sessionID: SessionID, timeout: TimeInterval? = nil, onTimeout: @escaping () -> Void) {
        var pendingItem: DispatchWorkItem?
        var delay: TimeInterval = 0

        stateQueue.sync {
            guard currentSessionID == sessionID else { return }
            cancelWatchdogLocked()

            delay = max(0, timeout ?? watchdogTimeoutSeconds)
            let item = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                let shouldFire = self.stateQueue.sync {
                    guard self.currentSessionID == sessionID else { return false }
                    self.currentSessionID = nil
                    self.watchdogWorkItem = nil
                    return true
                }
                if shouldFire {
                    onTimeout()
                }
            }
            watchdogWorkItem = item
            pendingItem = item
        }

        if let item = pendingItem {
            watchdogQueue.asyncAfter(deadline: .now() + delay, execute: item)
        }
    }

    private func cancelWatchdogLocked() {
        watchdogWorkItem?.cancel()
        watchdogWorkItem = nil
    }
}
