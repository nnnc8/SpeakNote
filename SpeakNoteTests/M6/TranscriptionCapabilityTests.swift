import Foundation
import XCTest

@testable import SpeakNote

final class TranscriptionCapabilityTests: XCTestCase {
  private let resolver = TranscriptionCapabilityResolver()

  func testOperatingSystemMatrixChoosesRequiredBackend() {
    let cases: [(Int, TimeInterval, TranscriptionCapability)] = [
      (14, 54.9, .available(.legacyOnDevice)),
      (15, 54.9, .available(.legacyOnDevice)),
      (26, 3_600, .available(.speechAnalyzer)),
      (27, 3_600, .available(.speechAnalyzer)),
    ]

    for (majorVersion, duration, expected) in cases {
      let modelAssetState: SpeechModelAssetState =
        majorVersion >= 26 ? .installed : .notRequired
      XCTAssertEqual(
        resolver.resolve(
          input(
            macOSMajorVersion: majorVersion,
            duration: duration,
            modelAssetState: modelAssetState
          )
        ),
        expected,
        "macOS \(majorVersion)"
      )
    }
  }

  func testLegacyDurationBoundaryIsStrictlyLessThan55Seconds() {
    XCTAssertEqual(
      resolver.resolve(input(macOSMajorVersion: 15, duration: 54.9)),
      .available(.legacyOnDevice)
    )
    XCTAssertEqual(
      resolver.resolve(input(macOSMajorVersion: 15, duration: 55.1)),
      .unavailable(.legacyDurationLimitExceeded)
    )
    XCTAssertEqual(
      resolver.resolve(input(macOSMajorVersion: 15, duration: 55)),
      .unavailable(.legacyDurationLimitExceeded)
    )
  }

  func testUnsupportedLocaleIsUnavailableOnBothBackends() {
    for majorVersion in [14, 15, 26, 27] {
      XCTAssertEqual(
        resolver.resolve(
          input(
            macOSMajorVersion: majorVersion,
            supportsLocale: false,
            modelAssetState: majorVersion >= 26 ? .installed : .notRequired
          )
        ),
        .unavailable(.unsupportedLocale)
      )
    }
  }

  func testRecognizerAvailabilityIsReportedBeforeUnsupportedLocale() {
    for majorVersion in [15, 26] {
      XCTAssertEqual(
        resolver.resolve(
          input(
            macOSMajorVersion: majorVersion,
            isAvailable: false,
            supportsLocale: false,
            modelAssetState: majorVersion >= 26 ? .installed : .notRequired
          )
        ),
        .unavailable(.recognizerUnavailable)
      )
    }
  }

  func testPermissionStatesAreDeterministic() {
    XCTAssertEqual(
      resolver.resolve(input(authorization: .notDetermined)),
      .unavailable(.permissionNotDetermined)
    )
    XCTAssertEqual(
      resolver.resolve(input(authorization: .denied)),
      .unavailable(.permissionDenied)
    )
    XCTAssertEqual(
      resolver.resolve(input(authorization: .restricted)),
      .unavailable(.permissionDenied)
    )
  }

  func testAnalyzerModelAssetStatesAreDistinguished() {
    XCTAssertEqual(
      resolver.resolve(
        input(macOSMajorVersion: 26, modelAssetState: .missing)
      ),
      .unavailable(.modelMissing)
    )
    XCTAssertEqual(
      resolver.resolve(
        input(macOSMajorVersion: 26, modelAssetState: .unavailable)
      ),
      .unavailable(.modelUnavailable)
    )
  }

  func testRecognizerAvailabilityAndOnDeviceRequirementsAreDistinct() {
    XCTAssertEqual(
      resolver.resolve(input(isAvailable: false)),
      .unavailable(.recognizerUnavailable)
    )
    XCTAssertEqual(
      resolver.resolve(input(supportsOnDeviceRecognition: false)),
      .unavailable(.onDeviceRecognitionUnavailable)
    )
  }

  func testFallbackPolicyNeverSilentlyCrossesPrivacyBoundary() {
    XCTAssertEqual(
      FallbackPolicy.never.decision(from: .local, to: .local),
      .denied
    )
    XCTAssertEqual(
      FallbackPolicy.samePrivacyClass.decision(from: .local, to: .local),
      .allowed
    )
    XCTAssertEqual(
      FallbackPolicy.samePrivacyClass.decision(from: .local, to: .cloud),
      .denied
    )
    XCTAssertEqual(
      FallbackPolicy.samePrivacyClass.decision(from: .cloud, to: .cloud),
      .allowed
    )
    XCTAssertEqual(
      FallbackPolicy.askBeforeCrossingBoundary.decision(
        from: .local,
        to: .local
      ),
      .allowed
    )
    XCTAssertEqual(
      FallbackPolicy.askBeforeCrossingBoundary.decision(
        from: .local,
        to: .cloud
      ),
      .requiresConsent
    )
    XCTAssertEqual(
      FallbackPolicy.askBeforeCrossingBoundary.decision(
        from: .local,
        to: .cloud,
        userConsented: true
      ),
      .allowed
    )
    XCTAssertEqual(
      FallbackPolicy.defaultValue,
      FallbackPolicy.askBeforeCrossingBoundary
    )
  }

  private func input(
    macOSMajorVersion: Int = 15,
    duration: TimeInterval = 10,
    authorization: SpeechAuthorizationState = .authorized,
    isAvailable: Bool = true,
    supportsLocale: Bool = true,
    supportsOnDeviceRecognition: Bool = true,
    modelAssetState: SpeechModelAssetState = .notRequired
  ) -> TranscriptionCapabilityInput {
    TranscriptionCapabilityInput(
      macOSMajorVersion: macOSMajorVersion,
      duration: duration,
      adapter: SpeechAdapterAvailability(
        authorization: authorization,
        isAvailable: isAvailable,
        supportsLocale: supportsLocale,
        supportsOnDeviceRecognition: supportsOnDeviceRecognition,
        modelAssetState: modelAssetState
      )
    )
  }
}
