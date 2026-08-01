import Foundation

struct TranscriptionRoutingRequest: Equatable, Sendable {
  let audioURL: URL
  let duration: TimeInterval
  let configuration: TranscriptionConfiguration
  let fallbackProviderID: ProviderID?
  let fallbackPolicy: FallbackPolicy
  let localOnly: Bool

  init(
    audioURL: URL,
    duration: TimeInterval,
    configuration: TranscriptionConfiguration,
    fallbackProviderID: ProviderID? = nil,
    fallbackPolicy: FallbackPolicy = .defaultValue,
    localOnly: Bool = false
  ) {
    self.audioURL = audioURL
    self.duration = duration
    self.configuration = configuration
    self.fallbackProviderID = fallbackProviderID
    self.fallbackPolicy = fallbackPolicy
    self.localOnly = localOnly
  }
}

enum TranscriptionFallbackReason: Equatable, Sendable {
  case providerUnavailable(TranscriptionUnavailableReason)
  case transcriptionFailed
}

struct TranscriptionFallbackOffer: Equatable, Sendable {
  let id: UInt64
  let sourceProviderID: ProviderID
  let destinationProviderID: ProviderID
  let sourcePrivacyClass: TranscriptionPrivacyClass
  let destinationPrivacyClass: TranscriptionPrivacyClass
  let reason: TranscriptionFallbackReason
  let audioURL: URL

  fileprivate init(
    id: UInt64,
    sourceProviderID: ProviderID,
    destinationProviderID: ProviderID,
    sourcePrivacyClass: TranscriptionPrivacyClass,
    destinationPrivacyClass: TranscriptionPrivacyClass,
    reason: TranscriptionFallbackReason,
    request: TranscriptionRoutingRequest
  ) {
    self.id = id
    self.sourceProviderID = sourceProviderID
    self.destinationProviderID = destinationProviderID
    self.sourcePrivacyClass = sourcePrivacyClass
    self.destinationPrivacyClass = destinationPrivacyClass
    self.reason = reason
    audioURL = request.audioURL
  }
}

enum TranscriptionRoutingOutcome: Equatable, Sendable {
  case completed(providerID: ProviderID, transcript: Transcript)
  case fallbackOffered(TranscriptionFallbackOffer)
  case fallbackDeclined(TranscriptionFallbackOffer)
}

enum TranscriptionProviderRouterError: Error, Equatable, Sendable {
  case unsupportedProvider(ProviderID)
  case providerUnavailable(
    providerID: ProviderID,
    reason: TranscriptionUnavailableReason
  )
  case localOnlyRequiresLocalProvider(ProviderID)
  case invalidFallbackOffer
}

protocol TranscriptionProviderRouting: Actor {
  func transcribe(
    _ request: TranscriptionRoutingRequest
  ) async throws -> TranscriptionRoutingOutcome

  func accept(
    _ offer: TranscriptionFallbackOffer
  ) async throws -> TranscriptionRoutingOutcome

  func decline(
    _ offer: TranscriptionFallbackOffer
  ) -> TranscriptionRoutingOutcome
}

actor TranscriptionProviderRouter: TranscriptionProviderRouting {
  private struct Endpoint: Sendable {
    let privacyClass: TranscriptionPrivacyClass
    let engine: any TranscriptionEngine
    let capability: any TranscriptionProviderCapabilityChecking
  }

  private struct PendingFallback: Sendable {
    let offer: TranscriptionFallbackOffer
    let request: TranscriptionRoutingRequest
  }

  private let providers: [ProviderID: Endpoint]
  private var nextOfferID: UInt64 = 0
  private var pendingFallbacks: [UInt64: PendingFallback] = [:]

  init(
    appleSpeechEngine: any TranscriptionEngine,
    appleSpeechCapability: any TranscriptionProviderCapabilityChecking,
    groqEngine: any TranscriptionEngine,
    groqCapability: any TranscriptionProviderCapabilityChecking
  ) {
    providers = [
      .appleSpeech: Endpoint(
        privacyClass: .local,
        engine: appleSpeechEngine,
        capability: appleSpeechCapability
      ),
      .groq: Endpoint(
        privacyClass: .cloud,
        engine: groqEngine,
        capability: groqCapability
      ),
    ]
  }

  func transcribe(
    _ request: TranscriptionRoutingRequest
  ) async throws -> TranscriptionRoutingOutcome {
    let sourceID = request.configuration.providerID
    let source = try endpoint(for: sourceID)
    guard !request.localOnly || source.privacyClass == .local else {
      throw TranscriptionProviderRouterError.localOnlyRequiresLocalProvider(
        sourceID
      )
    }

    switch await capability(of: source, for: request) {
    case .available:
      do {
        return try await execute(source, providerID: sourceID, request: request)
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        if let fallback = try await fallbackOutcome(
          for: request,
          sourceID: sourceID,
          source: source,
          reason: .transcriptionFailed
        ) {
          return fallback
        }
        throw error
      }
    case .unavailable(let reason):
      if let fallback = try await fallbackOutcome(
        for: request,
        sourceID: sourceID,
        source: source,
        reason: .providerUnavailable(reason)
      ) {
        return fallback
      }
      throw TranscriptionProviderRouterError.providerUnavailable(
        providerID: sourceID,
        reason: reason
      )
    }
  }

  func accept(
    _ offer: TranscriptionFallbackOffer
  ) async throws -> TranscriptionRoutingOutcome {
    guard
      let pendingFallback = pendingFallbacks[offer.id],
      pendingFallback.offer == offer
    else {
      throw TranscriptionProviderRouterError.invalidFallbackOffer
    }
    let request = pendingFallback.request
    guard
      request.configuration.providerID == offer.sourceProviderID,
      request.fallbackProviderID == offer.destinationProviderID
    else {
      throw TranscriptionProviderRouterError.invalidFallbackOffer
    }

    let source = try endpoint(for: offer.sourceProviderID)
    let destination = try endpoint(for: offer.destinationProviderID)
    guard
      source.privacyClass == offer.sourcePrivacyClass,
      destination.privacyClass == offer.destinationPrivacyClass,
      request.fallbackPolicy.decision(
        from: source.privacyClass,
        to: destination.privacyClass,
        userConsented: true
      ) == .allowed
    else {
      throw TranscriptionProviderRouterError.invalidFallbackOffer
    }
    guard !request.localOnly || destination.privacyClass == .local else {
      throw TranscriptionProviderRouterError.localOnlyRequiresLocalProvider(
        offer.destinationProviderID
      )
    }
    pendingFallbacks.removeValue(forKey: offer.id)

    switch await capability(of: destination, for: request) {
    case .available:
      return try await execute(
        destination,
        providerID: offer.destinationProviderID,
        request: request
      )
    case .unavailable(let reason):
      throw TranscriptionProviderRouterError.providerUnavailable(
        providerID: offer.destinationProviderID,
        reason: reason
      )
    }
  }

  func decline(
    _ offer: TranscriptionFallbackOffer
  ) -> TranscriptionRoutingOutcome {
    if pendingFallbacks[offer.id]?.offer == offer {
      pendingFallbacks.removeValue(forKey: offer.id)
    }
    return .fallbackDeclined(offer)
  }

  private func fallbackOutcome(
    for request: TranscriptionRoutingRequest,
    sourceID: ProviderID,
    source: Endpoint,
    reason: TranscriptionFallbackReason
  ) async throws -> TranscriptionRoutingOutcome? {
    guard
      let destinationID = request.fallbackProviderID,
      destinationID != sourceID
    else {
      return nil
    }
    let destination = try endpoint(for: destinationID)
    guard !request.localOnly || destination.privacyClass == .local else {
      return nil
    }
    let decision = request.fallbackPolicy.decision(
      from: source.privacyClass,
      to: destination.privacyClass
    )
    guard decision != .denied else {
      return nil
    }
    guard case .available = await capability(of: destination, for: request) else {
      return nil
    }

    switch decision {
    case .allowed:
      return try await execute(
        destination,
        providerID: destinationID,
        request: request
      )
    case .requiresConsent:
      nextOfferID &+= 1
      let offer = TranscriptionFallbackOffer(
        id: nextOfferID,
        sourceProviderID: sourceID,
        destinationProviderID: destinationID,
        sourcePrivacyClass: source.privacyClass,
        destinationPrivacyClass: destination.privacyClass,
        reason: reason,
        request: request
      )
      pendingFallbacks[offer.id] = PendingFallback(
        offer: offer,
        request: request
      )
      return .fallbackOffered(
        offer
      )
    case .denied:
      return nil
    }
  }

  private func endpoint(for providerID: ProviderID) throws -> Endpoint {
    guard let endpoint = providers[providerID] else {
      throw TranscriptionProviderRouterError.unsupportedProvider(providerID)
    }
    return endpoint
  }

  private func capability(
    of endpoint: Endpoint,
    for request: TranscriptionRoutingRequest
  ) async -> ProviderTranscriptionCapability {
    await endpoint.capability.providerCapability(
      for: TranscriptionCapabilityRequest(
        duration: request.duration,
        languageCode: request.configuration.languageCode
      )
    )
  }

  private func execute(
    _ endpoint: Endpoint,
    providerID: ProviderID,
    request: TranscriptionRoutingRequest
  ) async throws -> TranscriptionRoutingOutcome {
    var configuration = request.configuration
    configuration.providerID = providerID
    let transcript = try await endpoint.engine.transcribe(
      audioURL: request.audioURL,
      configuration: configuration
    )
    return .completed(providerID: providerID, transcript: transcript)
  }
}
