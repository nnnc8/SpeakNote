import CryptoKit
import Foundation
import XCTest

@testable import SpeakNote

final class BreezeASRTests: XCTestCase {
  func testGroqNormalizesBCP47SettingsToISO6391() {
    XCTAssertEqual(GroqTranscriptionEngine.apiLanguageCode("zh-TW"), "zh")
    XCTAssertEqual(GroqTranscriptionEngine.apiLanguageCode("en_US"), "en")
    XCTAssertNil(GroqTranscriptionEngine.apiLanguageCode("xx-XX"))
    XCTAssertNil(GroqTranscriptionEngine.apiLanguageCode(nil))
  }

  func testProviderIsLocalAndHasDedicatedModelCatalog() {
    XCTAssertEqual(ProviderID.breezeASR.rawValue, "breeze-asr")
    XCTAssertEqual(ProviderID.breezeASR.privacyClass, .local)
    XCTAssertTrue(ProviderID.breezeASR.isLocalTranscriptionProvider)
    XCTAssertEqual(BreezeTranscriptionModelCatalog.options.count, 1)
    XCTAssertEqual(BreezeTranscriptionModel.defaultID, "breeze-q5_0")
  }

  func testProviderIDPersistsThroughAppSettings() throws {
    let settings = AppSettings(
      transcriptionProviderID: .breezeASR,
      transcriptionModelID: BreezeTranscriptionModel.defaultID
    )
    let data = try JSONEncoder().encode(settings)
    let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
    XCTAssertEqual(decoded.transcriptionProviderID, .breezeASR)
    XCTAssertEqual(decoded.transcriptionModelID, BreezeTranscriptionModel.defaultID)
  }

  @MainActor
  func testLocalOnlyPreservesBreezeProvider() async {
    let store = FakeBreezeSettingsStore(
      settings: AppSettings(
        transcriptionProviderID: .breezeASR,
        transcriptionModelID: BreezeTranscriptionModel.defaultID,
        localOnly: false
      )
    )
    let coordinator = SettingsCoordinator(
      settingsRepository: store,
      keychainService: FakeBreezeAPIKeyStore()
    )
    await coordinator.load()
    coordinator.setLocalOnly(true)
    await coordinator.saveSettings()
    let saved = await store.loadValue()
    XCTAssertEqual(saved.transcriptionProviderID, .breezeASR)
    XCTAssertTrue(saved.localOnly)
  }

  func testModelDirectoryAndStateDoNotRequireTheModelBinary() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("BreezeASR-\(UUID().uuidString)")
    let store = try BreezeModelStore(rootURL: root)

    XCTAssertEqual(
      BreezeModelStore.modelDirectoryURL(
        applicationSupportURL: URL(fileURLWithPath: "/tmp/Application Support")
      ).path,
      "/tmp/Application Support/SpeakNote/Models/Breeze-ASR-26"
    )
    let initialState = await store.state(for: BreezeTranscriptionModel.defaultID)
    XCTAssertEqual(initialState, .notDownloaded)
    do {
      _ = try await store.modelURL(for: BreezeTranscriptionModel.defaultID)
      XCTFail("A missing model must not be returned as installed")
    } catch {
      XCTAssertEqual(error as? BreezeModelStoreError, .modelNotInstalled)
    }
    try await store.delete(modelID: BreezeTranscriptionModel.defaultID)
    let deletedState = await store.state(for: BreezeTranscriptionModel.defaultID)
    XCTAssertEqual(deletedState, .notDownloaded)
  }

  func testDeletingBreezeModelRemovesPartialDownload() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("BreezePartial-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let partialURL = root.appendingPathComponent("breeze-q5_0.bin.partial")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("partial".utf8).write(to: partialURL)
    let store = try BreezeModelStore(rootURL: root)

    try await store.delete(modelID: BreezeTranscriptionModel.defaultID)

    XCTAssertFalse(FileManager.default.fileExists(atPath: partialURL.path))
  }

  func testStateReportsCorruptedInstalledFile() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("BreezeCorrupt-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let modelURL = root.appendingPathComponent("breeze-q5_0.bin")
    try Data("corrupt".utf8).write(to: modelURL)
    let store = try BreezeModelStore(rootURL: root)

    let state = await store.state(for: BreezeTranscriptionModel.defaultID)

    XCTAssertEqual(state, .failed(.partialModel))
  }

  func testIntegrityVerifierAcceptsMatchingFile() throws {
    let data = Data("breeze-fixture".utf8)
    let fileURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("breeze-fixture-\(UUID().uuidString).bin")
    defer { try? FileManager.default.removeItem(at: fileURL) }
    try data.write(to: fileURL, options: .atomic)
    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    let metadata = BreezeModelMetadata(
      modelID: "fixture",
      fileName: fileURL.lastPathComponent,
      downloadURL: URL(string: "https://example.invalid/fixture")!,
      expectedByteCount: Int64(data.count),
      expectedSHA256: digest
    )

    XCTAssertNoThrow(
      try BreezeModelIntegrityVerifier.verify(fileURL: fileURL, metadata: metadata)
    )
  }

  func testIntegrityVerifierRejectsPartialAndWrongDigest() throws {
    let data = Data("partial".utf8)
    let fileURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("breeze-partial-\(UUID().uuidString).bin")
    defer { try? FileManager.default.removeItem(at: fileURL) }
    try data.write(to: fileURL, options: .atomic)
    let metadata = BreezeModelMetadata(
      modelID: "fixture",
      fileName: fileURL.lastPathComponent,
      downloadURL: URL(string: "https://example.invalid/fixture")!,
      expectedByteCount: Int64(data.count + 1),
      expectedSHA256: String(repeating: "0", count: 64)
    )

    XCTAssertThrowsError(
      try BreezeModelIntegrityVerifier.verify(fileURL: fileURL, metadata: metadata)
    ) { error in
      XCTAssertEqual(error as? BreezeModelStoreError, .partialModel)
    }
  }

  func testBreezeCapabilityReportsMissingModelWithoutCloudFallback() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("BreezeCapability-\(UUID().uuidString)")
    let store = try BreezeModelStore(rootURL: root)
    let capability = BreezeTranscriptionCapability(modelManager: store)
    let capabilityState = await capability.providerCapability(
      for: TranscriptionCapabilityRequest(duration: 4, languageCode: "zh-TW")
    )
    XCTAssertEqual(capabilityState, .unavailable(.modelMissing))

    let breeze = BreezeTestEngine(result: .failure(.failed))
    let groq = BreezeTestEngine(result: .success(Transcript(text: "must not upload")))
    let router = TranscriptionProviderRouter(
      endpoints: [
        .breezeASR: TranscriptionProviderEndpoint(
          privacyClass: .local,
          engine: breeze,
          capability: ConstantTranscriptionCapabilityChecker(.available)
        ),
        .groq: TranscriptionProviderEndpoint(
          privacyClass: .cloud,
          engine: groq,
          capability: ConstantTranscriptionCapabilityChecker(.available)
        ),
      ]
    )
    let outcome = try await router.transcribe(
      TranscriptionRoutingRequest(
        audioURL: URL(fileURLWithPath: "/tmp/breeze.wav"),
        duration: 4,
        configuration: TranscriptionConfiguration(
          providerID: .breezeASR,
          modelID: BreezeTranscriptionModel.defaultID,
          languageCode: "zh-TW"
        ),
        fallbackProviderID: .groq,
        fallbackPolicy: .askBeforeCrossingBoundary
      )
    )
    guard case .fallbackOffered(let offer) = outcome else {
      return XCTFail("A local failure should offer, not silently execute, cloud fallback")
    }
    XCTAssertEqual(offer.destinationProviderID, .groq)
    let groqCallCount = await groq.callCount
    XCTAssertEqual(groqCallCount, 0)
  }

  func testQuickDictationRouterCanExecuteBreezeWithoutCloudFallback() async throws {
    let breeze = BreezeTestEngine(
      result: .success(Transcript(text: "台語測試"))
    )
    let router = TranscriptionProviderRouter(
      endpoints: [
        .breezeASR: TranscriptionProviderEndpoint(
          privacyClass: .local,
          engine: breeze,
          capability: ConstantTranscriptionCapabilityChecker(.available)
        )
      ]
    )
    let outcome = try await router.transcribe(
      TranscriptionRoutingRequest(
        audioURL: URL(fileURLWithPath: "/tmp/breeze-quick.wav"),
        duration: 2,
        configuration: TranscriptionConfiguration(
          providerID: .breezeASR,
          modelID: BreezeTranscriptionModel.defaultID,
          languageCode: "zh-TW"
        ),
        fallbackProviderID: nil,
        fallbackPolicy: .never
      )
    )
    guard case .completed(_, let transcript) = outcome else {
      return XCTFail("Quick Dictation should execute the selected Breeze provider")
    }
    XCTAssertEqual(transcript.text, "台語測試")
    let callCount = await breeze.callCount
    XCTAssertEqual(callCount, 1)
  }

  func testVoiceNoteDispatchesBreezeThroughSharedEngineBoundary() async throws {
    let breeze = BreezeTestEngine(
      result: .success(Transcript(text: "台語 Voice Note"))
    )
    let dispatcher = ProviderDispatchingTranscriptionEngine(
      appleSpeech: BreezeTestEngine(result: .success(Transcript(text: "Apple"))),
      groq: BreezeTestEngine(result: .success(Transcript(text: "Groq"))),
      breeze: breeze
    )

    let transcript = try await dispatcher.transcribe(
      audioURL: URL(fileURLWithPath: "/tmp/breeze-voice-note.wav"),
      configuration: TranscriptionConfiguration(
        providerID: .breezeASR,
        modelID: BreezeTranscriptionModel.defaultID,
        languageCode: "zh-TW"
      )
    )

    XCTAssertEqual(transcript.text, "台語 Voice Note")
    let callCount = await breeze.callCount
    XCTAssertEqual(callCount, 1)
  }

  func testModelDownloadVerifiesAndAtomicallyInstallsFixture() async throws {
    let data = Data("breeze-fixture-model".utf8)
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("BreezeDownload-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let metadata = fixtureMetadata(
      modelID: "fixture",
      fileName: "fixture.bin",
      data: data
    )
    let streamer = FixtureBreezeDownloadStreaming { _ in
      fixtureDownloadResponse(statusCode: 200, data: data)
    }
    let store = try BreezeModelStore(
      rootURL: root,
      diskCapacityChecker: ConstantDiskCapacityChecker(capacity: 1_000_000_000),
      downloadStreaming: streamer,
      metadata: [metadata.modelID: metadata]
    )

    try await store.download(modelID: metadata.modelID)

    let state = await store.state(for: metadata.modelID)
    XCTAssertEqual(state, .installed)
    XCTAssertEqual(
      try Data(contentsOf: root.appendingPathComponent(metadata.fileName)),
      data
    )
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: root.appendingPathComponent("fixture.bin.partial").path
      )
    )

    try Data("xxxxxxxxxxxxxxxxxxxx".utf8).write(
      to: root.appendingPathComponent(metadata.fileName),
      options: .atomic
    )
    do {
      _ = try await store.modelURL(for: metadata.modelID)
      XCTFail("A modified installed file must be re-verified before use")
    } catch {
      XCTAssertEqual(error as? BreezeModelStoreError, .checksumMismatch)
    }
    let corruptedState = await store.state(for: metadata.modelID)
    XCTAssertEqual(corruptedState, .failed(.checksumMismatch))
  }

  func testModelDownloadResumesPartialFileWithRangeRequest() async throws {
    let fullData = Data("breeze-resumable-model".utf8)
    let partialData = fullData.prefix(7)
    let remainingData = fullData.dropFirst(7)
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("BreezeResume-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data(partialData).write(
      to: root.appendingPathComponent("fixture.bin.partial")
    )
    let metadata = fixtureMetadata(
      modelID: "fixture",
      fileName: "fixture.bin",
      data: fullData
    )
    let observedRanges = StringRecorder()
    let streamer = FixtureBreezeDownloadStreaming { request in
      observedRanges.append(request.value(forHTTPHeaderField: "Range"))
      return fixtureDownloadResponse(
        statusCode: 206,
        data: Data(remainingData)
      )
    }
    let store = try BreezeModelStore(
      rootURL: root,
      diskCapacityChecker: ConstantDiskCapacityChecker(capacity: 1_000_000_000),
      downloadStreaming: streamer,
      metadata: [metadata.modelID: metadata]
    )

    try await store.download(modelID: metadata.modelID)

    XCTAssertEqual(
      try Data(contentsOf: root.appendingPathComponent(metadata.fileName)),
      fullData
    )
    XCTAssertEqual(observedRanges.values(), ["bytes=7-"])
  }

  func testModelDownloadRejectsChecksumMismatchAndRemovesPartialFile() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("BreezeChecksum-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let metadata = fixtureMetadata(
      modelID: "fixture",
      fileName: "fixture.bin",
      data: Data("expected".utf8)
    )
    let streamer = FixtureBreezeDownloadStreaming { _ in
      fixtureDownloadResponse(statusCode: 200, data: Data("corrupt!".utf8))
    }
    let store = try BreezeModelStore(
      rootURL: root,
      diskCapacityChecker: ConstantDiskCapacityChecker(capacity: 1_000_000_000),
      downloadStreaming: streamer,
      metadata: [metadata.modelID: metadata]
    )

    do {
      try await store.download(modelID: metadata.modelID)
      XCTFail("A checksum mismatch must not install the model")
    } catch {
      XCTAssertEqual(error as? BreezeModelStoreError, .checksumMismatch)
    }
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: root.appendingPathComponent("fixture.bin").path
      )
    )
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: root.appendingPathComponent("fixture.bin.partial").path
      )
    )
  }

  func testModelDownloadRejectsInsufficientDiskBeforeNetworkRequest() async throws {
    let data = Data("fixture".utf8)
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("BreezeDisk-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let metadata = fixtureMetadata(
      modelID: "fixture",
      fileName: "fixture.bin",
      data: data
    )
    let requests = StringRecorder()
    let streamer = FixtureBreezeDownloadStreaming { request in
      requests.append(request.url?.absoluteString)
      return fixtureDownloadResponse(statusCode: 200, data: data)
    }
    let store = try BreezeModelStore(
      rootURL: root,
      diskCapacityChecker: ConstantDiskCapacityChecker(capacity: 0),
      downloadStreaming: streamer,
      metadata: [metadata.modelID: metadata]
    )

    do {
      try await store.download(modelID: metadata.modelID)
      XCTFail("Insufficient disk space must stop before network access")
    } catch {
      XCTAssertEqual(error as? BreezeModelStoreError, .insufficientDiskSpace)
    }
    XCTAssertTrue(requests.values().isEmpty)
    let state = await store.state(for: metadata.modelID)
    XCTAssertEqual(state, .failed(.insufficientDiskSpace))
  }

  func testModelLifecycleExposesLoadingAndReadyStates() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("BreezeLifecycle-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let metadata = fixtureMetadata(
      modelID: "fixture",
      fileName: "fixture.bin",
      data: Data("ready".utf8)
    )
    let store = try BreezeModelStore(
      rootURL: root,
      diskCapacityChecker: ConstantDiskCapacityChecker(capacity: 1_000_000_000),
      metadata: [metadata.modelID: metadata]
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("ready".utf8).write(to: root.appendingPathComponent(metadata.fileName))

    await store.markLoading(modelID: metadata.modelID)
    let loadingState = await store.state(for: metadata.modelID)
    XCTAssertEqual(loadingState, .loading)
    await store.markReady(modelID: metadata.modelID)
    let readyState = await store.state(for: metadata.modelID)
    XCTAssertEqual(readyState, .ready)
  }
}

private enum BreezeTestFailure: Error, Equatable {
  case failed
}

private actor BreezeTestEngine: TranscriptionEngine {
  let result: Result<Transcript, BreezeTestFailure>
  private(set) var callCount = 0

  init(result: Result<Transcript, BreezeTestFailure>) {
    self.result = result
  }

  func transcribe(
    audioURL _: URL,
    configuration _: TranscriptionConfiguration
  ) throws -> Transcript {
    callCount += 1
    return try result.get()
  }
}

private actor FakeBreezeSettingsStore: SettingsStoring {
  private var value: AppSettings

  init(settings: AppSettings) {
    value = settings
  }

  func load() throws -> AppSettings { value }
  func save(_ settings: AppSettings) throws { value = settings }
  func reset() { value = .defaultValue }
  func loadValue() -> AppSettings { value }
}

private actor FakeBreezeAPIKeyStore: APIKeyStoring {
  func loadAPIKey() throws -> String? { nil }
  func saveAPIKey(_: String) throws {}
  func deleteAPIKey() throws {}
}

private struct ConstantDiskCapacityChecker: DiskCapacityChecking {
  let capacity: Int64

  func availableCapacity(at _: URL) async throws -> Int64 {
    capacity
  }
}

private final class StringRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [String?] = []

  func append(_ value: String?) {
    lock.withLock { storage.append(value) }
  }

  func values() -> [String?] {
    lock.withLock { storage }
  }
}

private func fixtureMetadata(
  modelID: String,
  fileName: String,
  data: Data
) -> BreezeModelMetadata {
  let digest = SHA256.hash(data: data)
    .map { String(format: "%02x", $0) }
    .joined()
  return BreezeModelMetadata(
    modelID: modelID,
    fileName: fileName,
    downloadURL: URL(string: "https://breeze.test/\(fileName)")!,
    expectedByteCount: Int64(data.count),
    expectedSHA256: digest
  )
}

private struct FixtureBreezeDownloadStreaming: BreezeDownloadStreaming {
  let response: @Sendable (URLRequest) -> BreezeDownloadResponse

  func stream(for request: URLRequest) async throws -> BreezeDownloadResponse {
    response(request)
  }
}

private func fixtureDownloadResponse(
  statusCode: Int,
  data: Data
) -> BreezeDownloadResponse {
  let stream = AsyncThrowingStream<UInt8, Error> { continuation in
    for byte in data {
      continuation.yield(byte)
    }
    continuation.finish()
  }
  return BreezeDownloadResponse(statusCode: statusCode, bytes: stream)
}
