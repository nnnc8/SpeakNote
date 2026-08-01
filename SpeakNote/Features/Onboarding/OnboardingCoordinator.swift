import Combine
import Foundation

enum OnboardingStep: Int, CaseIterable, Equatable, Sendable {
  case privacy
  case microphone
  case hotkey
  case localSpeech
}

@MainActor
final class OnboardingCoordinator: ObservableObject {
  @Published private(set) var isPresented = false
  @Published private(set) var step: OnboardingStep = .privacy
  @Published private(set) var permissions: PermissionSnapshot
  @Published private(set) var isBusy = false
  @Published var errorMessage: String?

  private let settingsRepository: any SettingsStoring
  private let permissionCenter: PermissionCenter
  private let refreshHotkey: @MainActor @Sendable () -> Void

  init(
    settingsRepository: any SettingsStoring,
    permissionCenter: PermissionCenter,
    refreshHotkey: @escaping @MainActor @Sendable () -> Void = {}
  ) {
    self.settingsRepository = settingsRepository
    self.permissionCenter = permissionCenter
    self.refreshHotkey = refreshHotkey
    permissions = permissionCenter.snapshot
  }

  func load() async {
    permissionCenter.refresh()
    permissions = permissionCenter.snapshot
    do {
      let settings = try await settingsRepository.load()
      isPresented = !settings.hasCompletedOnboarding
    } catch {
      errorMessage = String(localized: "Onboarding status could not be loaded.")
      isPresented = true
    }
  }

  func advance() {
    guard let next = OnboardingStep(rawValue: step.rawValue + 1) else {
      return
    }
    step = next
  }

  func goBack() {
    guard let previous = OnboardingStep(rawValue: step.rawValue - 1) else {
      return
    }
    step = previous
  }

  func request(_ permission: PermissionKind) async {
    isBusy = true
    defer { isBusy = false }
    await permissionCenter.request(permission)
    permissions = permissionCenter.snapshot
    if permission == .listenEvents {
      refreshHotkey()
    }
  }

  func openSystemSettings(for permission: PermissionKind) {
    permissionCenter.openSystemSettings(for: permission)
  }

  func finish() async {
    isBusy = true
    defer { isBusy = false }
    do {
      var settings = try await settingsRepository.load()
      settings.hasCompletedOnboarding = true
      try await settingsRepository.save(settings)
      isPresented = false
    } catch {
      errorMessage = String(localized: "Onboarding could not be completed.")
    }
  }
}
