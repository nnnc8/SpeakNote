import XCTest

@testable import SpeakNote

@MainActor
final class OnboardingCoordinatorTests: XCTestCase {
  func testFreshInstallPresentsAndFinishPersistsCompletion() async throws {
    let settings = OnboardingSettingsStore(.defaultValue)
    let system = OnboardingPermissionSystem()
    let coordinator = OnboardingCoordinator(
      settingsRepository: settings,
      permissionCenter: PermissionCenter(system: system)
    )

    await coordinator.load()
    XCTAssertTrue(coordinator.isPresented)

    await coordinator.finish()

    XCTAssertFalse(coordinator.isPresented)
    let storedSettings = await settings.load()
    XCTAssertTrue(storedSettings.hasCompletedOnboarding)
  }

  func testRequestRefreshesPermissionAndHotkeyCapability() async {
    let settings = OnboardingSettingsStore(.defaultValue)
    let system = OnboardingPermissionSystem()
    var hotkeyRefreshCount = 0
    let coordinator = OnboardingCoordinator(
      settingsRepository: settings,
      permissionCenter: PermissionCenter(system: system),
      refreshHotkey: { hotkeyRefreshCount += 1 }
    )

    await coordinator.request(.listenEvents)

    XCTAssertEqual(coordinator.permissions.listenEvents, .granted)
    XCTAssertEqual(hotkeyRefreshCount, 1)
  }

  func testCompletedInstallDoesNotPresentOnboarding() async {
    let settings = OnboardingSettingsStore(
      AppSettings(hasCompletedOnboarding: true)
    )
    let coordinator = OnboardingCoordinator(
      settingsRepository: settings,
      permissionCenter: PermissionCenter(
        system: OnboardingPermissionSystem()
      )
    )

    await coordinator.load()

    XCTAssertFalse(coordinator.isPresented)
  }
}

private actor OnboardingSettingsStore: SettingsStoring {
  private var value: AppSettings

  init(_ value: AppSettings) {
    self.value = value
  }

  func load() -> AppSettings { value }
  func save(_ settings: AppSettings) { value = settings }
  func reset() { value = .defaultValue }
}

@MainActor
private final class OnboardingPermissionSystem: PermissionSystemAccessing {
  private var statuses: [PermissionKind: PermissionStatus] = [:]

  func status(for kind: PermissionKind) -> PermissionStatus {
    statuses[kind] ?? .notDetermined
  }

  func request(_ kind: PermissionKind) async {
    statuses[kind] = .granted
  }

  func openSystemSettings(for kind: PermissionKind) {}
}
