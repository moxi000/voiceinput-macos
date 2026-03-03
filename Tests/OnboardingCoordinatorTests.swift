import Testing
@testable import VoiceInput

struct OnboardingCoordinatorTests {
    @Test("引导状态机：按权限->Provider->快捷键->首次试录顺序推进并最终完成")
    func onboardingHappyPath() {
        let coordinator = OnboardingCoordinator()

        #expect(coordinator.currentStep == .permissions)
        #expect(coordinator.canCompleteCurrentStep() == false)
        #expect(coordinator.isCompleted == false)

        coordinator.updatePermissions(accessibility: true, microphone: false)
        #expect(coordinator.currentStep == .permissions)
        #expect(coordinator.canCompleteCurrentStep() == false)

        coordinator.updatePermissions(accessibility: true, microphone: true)
        #expect(coordinator.currentStep == .providerConnectivity)
        #expect(coordinator.canCompleteCurrentStep() == false)

        coordinator.updateProviderReachability(true)
        #expect(coordinator.currentStep == .hotkeyRecording)
        #expect(coordinator.canCompleteCurrentStep() == false)

        coordinator.updateHotkeyRecorded(true)
        #expect(coordinator.currentStep == .firstTrialRecording)
        #expect(coordinator.canCompleteCurrentStep() == false)

        coordinator.updateFirstTrialCompleted(true)
        #expect(coordinator.currentStep == .completed)
        #expect(coordinator.canCompleteCurrentStep() == true)
        #expect(coordinator.isCompleted == true)
    }

    @Test("引导状态机：后置步骤失效时应回退到对应阻塞步骤")
    func onboardingRegressesWhenPrerequisiteLost() {
        let coordinator = OnboardingCoordinator()

        coordinator.updatePermissions(accessibility: true, microphone: true)
        coordinator.updateProviderReachability(true)
        coordinator.updateHotkeyRecorded(true)
        coordinator.updateFirstTrialCompleted(true)
        #expect(coordinator.currentStep == .completed)

        coordinator.updateProviderReachability(false)
        #expect(coordinator.currentStep == .providerConnectivity)
        #expect(coordinator.isCompleted == false)
    }

    @Test("引导状态机：reset 可恢复初始状态")
    func onboardingReset() {
        let coordinator = OnboardingCoordinator()

        coordinator.updatePermissions(accessibility: true, microphone: true)
        coordinator.updateProviderReachability(true)
        coordinator.updateHotkeyRecorded(true)
        coordinator.updateFirstTrialCompleted(true)
        #expect(coordinator.isCompleted == true)

        coordinator.reset()
        #expect(coordinator.currentStep == .permissions)
        #expect(coordinator.canCompleteCurrentStep() == false)
        #expect(coordinator.isCompleted == false)
    }
}
