import Foundation
import XCTest

@testable import SpeakNote

final class TranscriptionProviderRouterTests: XCTestCase {
  func testCrossBoundaryFallbackCallsDestinationOnlyAfterAcceptance() async throws {
    let groq = M6RouterEngine(result: .failure(.requestFailed))
    let expectedTranscript = Transcript(text: "local result")
    let apple = M6RouterEngine(
      result: .success(expectedTranscript)
    )
    let router = makeRouter(apple: apple, groq: groq)
    let request = routingRequest(
      providerID: .groq,
      fallbackProviderID: .appleSpeech,
      fallbackPolicy: .askBeforeCrossingBoundary
    )

    let firstOutcome = try await router.transcribe(request)
    let firstOffer = try fallbackOffer(from: firstOutcome)
    var appleCalls = await apple.callCount
    XCTAssertEqual(appleCalls, 0)
    XCTAssertEqual(firstOffer.sourcePrivacyClass, .cloud)
    XCTAssertEqual(firstOffer.destinationPrivacyClass, .local)
    XCTAssertEqual(firstOffer.reason, .transcriptionFailed)
    XCTAssertEqual(firstOffer.audioURL, request.audioURL)

    let declined = await router.decline(firstOffer)
    XCTAssertEqual(declined, .fallbackDeclined(firstOffer))
    appleCalls = await apple.callCount
    XCTAssertEqual(appleCalls, 0)

    do {
      _ = try await router.accept(firstOffer)
      XCTFail("A declined fallback offer must be terminal")
    } catch {
      XCTAssertEqual(
        error as? TranscriptionProviderRouterError,
        .invalidFallbackOffer
      )
    }
    appleCalls = await apple.callCount
    XCTAssertEqual(appleCalls, 0)

    let secondOutcome = try await router.transcribe(request)
    let secondOffer = try fallbackOffer(from: secondOutcome)
    appleCalls = await apple.callCount
    XCTAssertEqual(appleCalls, 0)

    let accepted = try await router.accept(secondOffer)
    XCTAssertEqual(
      accepted,
      .completed(
        providerID: .appleSpeech,
        transcript: expectedTranscript
      )
    )
    appleCalls = await apple.callCount
    let appleConfigurations = await apple.configurations
    XCTAssertEqual(appleCalls, 1)
    XCTAssertEqual(appleConfigurations.map(\.providerID), [.appleSpeech])
  }

  func testUnavailablePrimaryOffersFallbackWithoutCallingEitherEngine() async throws {
    let groq = M6RouterEngine(result: .failure(.requestFailed))
    let apple = M6RouterEngine(
      result: .success(Transcript(text: "local result"))
    )
    let router = makeRouter(
      apple: apple,
      groq: groq,
      groqCapability: .unavailable(.providerNotConfigured)
    )

    let outcome = try await router.transcribe(
      routingRequest(
        providerID: .groq,
        fallbackProviderID: .appleSpeech,
        fallbackPolicy: .askBeforeCrossingBoundary
      )
    )
    let offer = try fallbackOffer(from: outcome)
    let groqCalls = await groq.callCount
    let appleCalls = await apple.callCount

    XCTAssertEqual(
      offer.reason,
      .providerUnavailable(.providerNotConfigured)
    )
    XCTAssertEqual(groqCalls, 0)
    XCTAssertEqual(appleCalls, 0)
  }

  func testAppleFailureDoesNotCallGroqBeforeCloudConsent() async throws {
    let apple = M6RouterEngine(result: .failure(.requestFailed))
    let groq = M6RouterEngine(
      result: .success(Transcript(text: "cloud result"))
    )
    let router = makeRouter(apple: apple, groq: groq)

    let outcome = try await router.transcribe(
      routingRequest(
        providerID: .appleSpeech,
        fallbackProviderID: .groq,
        fallbackPolicy: .askBeforeCrossingBoundary
      )
    )
    let offer = try fallbackOffer(from: outcome)
    var groqCalls = await groq.callCount

    XCTAssertEqual(offer.sourcePrivacyClass, .local)
    XCTAssertEqual(offer.destinationPrivacyClass, .cloud)
    XCTAssertEqual(groqCalls, 0)

    _ = try await router.accept(offer)
    groqCalls = await groq.callCount
    XCTAssertEqual(groqCalls, 1)
  }

  func testNeverPolicyDoesNotCallFallback() async {
    let groq = M6RouterEngine(result: .failure(.requestFailed))
    let apple = M6RouterEngine(
      result: .success(Transcript(text: "must not run"))
    )
    let router = makeRouter(apple: apple, groq: groq)

    do {
      _ = try await router.transcribe(
        routingRequest(
          providerID: .groq,
          fallbackProviderID: .appleSpeech,
          fallbackPolicy: .never
        )
      )
      XCTFail("Expected the primary provider error")
    } catch {
      XCTAssertEqual(error as? M6RouterFailure, .requestFailed)
    }

    let appleCalls = await apple.callCount
    XCTAssertEqual(appleCalls, 0)
  }

  func testLocalOnlyRejectsCloudPrimaryAndCloudFallback() async {
    let groq = M6RouterEngine(
      result: .success(Transcript(text: "must not run"))
    )
    let apple = M6RouterEngine(result: .failure(.requestFailed))
    let router = makeRouter(apple: apple, groq: groq)

    do {
      _ = try await router.transcribe(
        routingRequest(
          providerID: .groq,
          fallbackProviderID: .appleSpeech,
          localOnly: true
        )
      )
      XCTFail("Expected local-only rejection")
    } catch {
      XCTAssertEqual(
        error as? TranscriptionProviderRouterError,
        .localOnlyRequiresLocalProvider(.groq)
      )
    }
    var groqCalls = await groq.callCount
    XCTAssertEqual(groqCalls, 0)

    do {
      _ = try await router.transcribe(
        routingRequest(
          providerID: .appleSpeech,
          fallbackProviderID: .groq,
          localOnly: true
        )
      )
      XCTFail("Expected Apple provider error")
    } catch {
      XCTAssertEqual(error as? M6RouterFailure, .requestFailed)
    }
    groqCalls = await groq.callCount
    XCTAssertEqual(groqCalls, 0)
  }

  private func makeRouter(
    apple: M6RouterEngine,
    groq: M6RouterEngine,
    appleCapability: ProviderTranscriptionCapability = .available,
    groqCapability: ProviderTranscriptionCapability = .available
  ) -> TranscriptionProviderRouter {
    TranscriptionProviderRouter(
      appleSpeechEngine: apple,
      appleSpeechCapability: ConstantTranscriptionCapabilityChecker(
        appleCapability
      ),
      groqEngine: groq,
      groqCapability: ConstantTranscriptionCapabilityChecker(groqCapability)
    )
  }

  private func routingRequest(
    providerID: ProviderID,
    fallbackProviderID: ProviderID,
    fallbackPolicy: FallbackPolicy = .askBeforeCrossingBoundary,
    localOnly: Bool = false
  ) -> TranscriptionRoutingRequest {
    TranscriptionRoutingRequest(
      audioURL: URL(fileURLWithPath: "/tmp/m6-routing.m4a"),
      duration: 12,
      configuration: TranscriptionConfiguration(providerID: providerID),
      fallbackProviderID: fallbackProviderID,
      fallbackPolicy: fallbackPolicy,
      localOnly: localOnly
    )
  }

  private func fallbackOffer(
    from outcome: TranscriptionRoutingOutcome
  ) throws -> TranscriptionFallbackOffer {
    guard case .fallbackOffered(let offer) = outcome else {
      XCTFail("Expected a fallback offer")
      throw M6RouterFailure.unexpectedOutcome
    }
    return offer
  }
}

private enum M6RouterFailure: Error, Equatable {
  case requestFailed
  case unexpectedOutcome
}

private actor M6RouterEngine: TranscriptionEngine {
  let result: Result<Transcript, M6RouterFailure>
  private(set) var configurations: [TranscriptionConfiguration] = []

  init(result: Result<Transcript, M6RouterFailure>) {
    self.result = result
  }

  var callCount: Int { configurations.count }

  func transcribe(
    audioURL _: URL,
    configuration: TranscriptionConfiguration
  ) throws -> Transcript {
    configurations.append(configuration)
    return try result.get()
  }
}
