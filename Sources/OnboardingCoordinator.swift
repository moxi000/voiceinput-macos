import Foundation

enum OnboardingStep: Int, CaseIterable {
    case permissions
    case providerConnectivity
    case hotkeyRecording
    case firstTrialRecording
    case completed
}

final class OnboardingCoordinator {
    private(set) var accessibilityGranted = false
    private(set) var microphoneGranted = false
    private(set) var providerReachable = false
    private(set) var hotkeyRecorded = false
    private(set) var firstTrialCompleted = false

    var currentStep: OnboardingStep {
        if !permissionsReady { return .permissions }
        if !providerReachable { return .providerConnectivity }
        if !hotkeyRecorded { return .hotkeyRecording }
        if !firstTrialCompleted { return .firstTrialRecording }
        return .completed
    }

    var isCompleted: Bool {
        currentStep == .completed
    }

    func canCompleteCurrentStep() -> Bool {
        switch currentStep {
        case .permissions:
            return permissionsReady
        case .providerConnectivity:
            return providerReachable
        case .hotkeyRecording:
            return hotkeyRecorded
        case .firstTrialRecording:
            return firstTrialCompleted
        case .completed:
            return true
        }
    }

    func updatePermissions(accessibility: Bool, microphone: Bool) {
        accessibilityGranted = accessibility
        microphoneGranted = microphone
    }

    func updateProviderReachability(_ reachable: Bool) {
        providerReachable = reachable
    }

    func updateHotkeyRecorded(_ recorded: Bool) {
        hotkeyRecorded = recorded
    }

    func updateFirstTrialCompleted(_ completed: Bool) {
        firstTrialCompleted = completed
    }

    func reset() {
        accessibilityGranted = false
        microphoneGranted = false
        providerReachable = false
        hotkeyRecorded = false
        firstTrialCompleted = false
    }

    private var permissionsReady: Bool {
        accessibilityGranted && microphoneGranted
    }
}
