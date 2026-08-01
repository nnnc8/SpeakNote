import CryptoKit
import Foundation
import XCTest

@testable import SpeakNote

final class VoiceNoteTranscriptionPipelineTests: XCTestCase {
  func testProcessesChunksAndPersistsCheckpointRawTranscriptAndMarkdown() async throws {
    let fixture = try await makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
    let transcriber = PipelineFakeTranscriber()
    let pipeline = makePipeline(fixture: fixture, transcriber: transcriber)

    try await pipeline.process(
      sessionID: fixture.sessionID,
      jobID: fixture.jobID,
      sourceRelativePath: fixture.sourceRelativePath,
      sourceDuration: 6,
      configuration: TranscriptionConfiguration()
    )

    let session = try await fixture.repository.session(id: fixture.sessionID)
    let job = try await fixture.repository.job(id: fixture.jobID)
    let manifest = try await fixture.fileStore.manifest(sessionID: fixture.sessionID)
    let rawAsset = try XCTUnwrap(
      manifest.assets.first { $0.relativePath == "transcripts/raw-v1.json" }
    )
    let raw = try await fixture.fileStore.readJSON(
      Transcript.self,
      sessionID: fixture.sessionID,
      relativePath: rawAsset.relativePath,
      expectedSHA256: rawAsset.sha256
    )
    let markdownAsset = try XCTUnwrap(
      manifest.assets.first { $0.relativePath == "transcripts/raw-v1.md" }
    )
    let markdown = try await fixture.fileStore.readData(
      sessionID: fixture.sessionID,
      relativePath: markdownAsset.relativePath,
      expectedSHA256: markdownAsset.sha256
    )
    let checkpointAsset = try XCTUnwrap(
      manifest.assets.first { $0.kind == .checkpoint }
    )
    let checkpoint = try await fixture.fileStore.readJSON(
      TranscriptionCheckpoint.self,
      sessionID: fixture.sessionID,
      relativePath: checkpointAsset.relativePath,
      expectedSHA256: checkpointAsset.sha256
    )
    let calls = await transcriber.calledIndices()

    XCTAssertEqual(session?.status, .completed)
    XCTAssertEqual(job?.stage, .completed)
    XCTAssertEqual(job?.completedChunks, 2)
    XCTAssertEqual(job?.totalChunks, 2)
    XCTAssertEqual(raw.text, "alpha shared beta")
    XCTAssertEqual(String(decoding: markdown, as: UTF8.self), "# Voice note\nalpha shared beta\n")
    XCTAssertEqual(checkpoint.chunks.map(\.index), [0, 1])
    XCTAssertEqual(checkpoint.completedChunks.map(\.index), [0, 1])
    XCTAssertEqual(calls, [0, 1])
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: fixture.rootURL
          .appendingPathComponent("Temp/\(fixture.jobID.uuidString)")
          .path
      )
    )
  }

  func testRelaunchResumeSkipsCheckpointedChunkAfterAmbiguousCompletion() async throws {
    let fixture = try await makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
    let firstTranscriber = PipelineFakeTranscriber(mode: .ambiguous(index: 1))
    let firstPipeline = makePipeline(
      fixture: fixture,
      transcriber: firstTranscriber
    )

    do {
      try await firstPipeline.process(
        sessionID: fixture.sessionID,
        jobID: fixture.jobID,
        sourceRelativePath: fixture.sourceRelativePath,
        sourceDuration: 6,
        configuration: TranscriptionConfiguration()
      )
      XCTFail("Ambiguous completion must require an explicit resume.")
    } catch let error as GroqAPIError {
      XCTAssertEqual(error, .ambiguousCompletion)
    }
    let failedJob = try await fixture.repository.job(id: fixture.jobID)
    let failedSession = try await fixture.repository.session(id: fixture.sessionID)
    XCTAssertEqual(failedJob?.stage, .retryRequired)
    XCTAssertEqual(failedJob?.completedChunks, 1)
    XCTAssertEqual(
      failedJob?.errorCategory,
      "ambiguousCompletionConfirmationRequired"
    )
    XCTAssertEqual(failedSession?.status, .retryRequired)

    let resumedTranscriber = PipelineFakeTranscriber()
    let relaunchedPipeline = makePipeline(
      fixture: fixture,
      transcriber: resumedTranscriber
    )
    try await relaunchedPipeline.resume(
      sessionID: fixture.sessionID,
      configuration: TranscriptionConfiguration()
    )

    let resumedCalls = await resumedTranscriber.calledIndices()
    let completedJob = try await fixture.repository.job(id: fixture.jobID)
    let completedSession = try await fixture.repository.session(id: fixture.sessionID)
    XCTAssertEqual(resumedCalls, [1])
    XCTAssertEqual(completedJob?.stage, .completed)
    XCTAssertEqual(completedJob?.completedChunks, 2)
    XCTAssertEqual(completedSession?.status, .completed)
  }

  func testResumeUsesCheckpointedConfigurationInsteadOfCallerSettings() async throws {
    let fixture = try await makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
    let original = TranscriptionConfiguration(
      providerID: .groq,
      modelID: "frozen-model",
      languageCode: "zh-TW"
    )
    let firstPipeline = makePipeline(
      fixture: fixture,
      transcriber: PipelineFakeTranscriber(mode: .cancel(index: 1))
    )

    do {
      try await firstPipeline.process(
        sessionID: fixture.sessionID,
        jobID: fixture.jobID,
        sourceRelativePath: fixture.sourceRelativePath,
        sourceDuration: 6,
        configuration: original
      )
      XCTFail("Fixture must stop with one completed provider response.")
    } catch is CancellationError {
      // Expected.
    }

    let resumedTranscriber = PipelineFakeTranscriber()
    let relaunchedPipeline = makePipeline(
      fixture: fixture,
      transcriber: resumedTranscriber
    )
    try await relaunchedPipeline.resume(
      sessionID: fixture.sessionID,
      configuration: TranscriptionConfiguration(
        providerID: .appleSpeech,
        modelID: "changed-after-relaunch",
        languageCode: "en-US"
      )
    )

    let resumedConfigurations = await resumedTranscriber.calledConfigurations()
    XCTAssertEqual(resumedConfigurations, [original])
  }

  func testCancellationKeepsCompletedChunkAndCheckpointForResume() async throws {
    let fixture = try await makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
    let transcriber = PipelineFakeTranscriber(mode: .cancel(index: 1))
    let pipeline = makePipeline(fixture: fixture, transcriber: transcriber)

    do {
      try await pipeline.process(
        sessionID: fixture.sessionID,
        jobID: fixture.jobID,
        sourceRelativePath: fixture.sourceRelativePath,
        sourceDuration: 6,
        configuration: TranscriptionConfiguration()
      )
      XCTFail("Cancellation must leave the job paused at its checkpoint.")
    } catch is CancellationError {
      // Expected.
    }

    let session = try await fixture.repository.session(id: fixture.sessionID)
    let job = try await fixture.repository.job(id: fixture.jobID)
    let manifest = try await fixture.fileStore.manifest(sessionID: fixture.sessionID)
    let checkpointAsset = try XCTUnwrap(
      manifest.assets.first { $0.kind == .checkpoint }
    )
    let checkpoint = try await fixture.fileStore.readJSON(
      TranscriptionCheckpoint.self,
      sessionID: fixture.sessionID,
      relativePath: checkpointAsset.relativePath,
      expectedSHA256: checkpointAsset.sha256
    )

    XCTAssertEqual(session?.status, .cancelled)
    XCTAssertEqual(job?.stage, .cancelled)
    XCTAssertEqual(job?.completedChunks, 1)
    XCTAssertEqual(manifest.state, .ready)
    XCTAssertEqual(checkpoint.completedChunks.map(\.index), [0])
    XCTAssertEqual(checkpoint.chunks.map(\.index), [0, 1])

    let resumedTranscriber = PipelineFakeTranscriber()
    let relaunchedPipeline = makePipeline(
      fixture: fixture,
      transcriber: resumedTranscriber
    )
    try await relaunchedPipeline.resume(
      sessionID: fixture.sessionID,
      configuration: TranscriptionConfiguration()
    )

    let resumedCalls = await resumedTranscriber.calledIndices()
    let completedSession = try await fixture.repository.session(
      id: fixture.sessionID
    )
    XCTAssertEqual(resumedCalls, [1])
    XCTAssertEqual(completedSession?.status, .completed)
  }

  func testResumeReconcilesCompletedDatabaseWithManifestWithoutRewritingOutputs()
    async throws
  {
    let fixture = try await makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
    let firstPipeline = makePipeline(
      fixture: fixture,
      transcriber: PipelineFakeTranscriber()
    )
    try await firstPipeline.process(
      sessionID: fixture.sessionID,
      jobID: fixture.jobID,
      sourceRelativePath: fixture.sourceRelativePath,
      sourceDuration: 6,
      configuration: TranscriptionConfiguration()
    )
    let completedManifest = try await fixture.fileStore.manifest(
      sessionID: fixture.sessionID
    )
    let originalOutputs = completedManifest.assets.filter {
      $0.relativePath == "transcripts/raw-v1.json"
        || $0.relativePath == "transcripts/raw-v1.md"
    }
    try await fixture.fileStore.updateState(
      sessionID: fixture.sessionID,
      state: .processing
    )

    let resumedTranscriber = PipelineFakeTranscriber()
    let relaunchedPipeline = makePipeline(
      fixture: fixture,
      transcriber: resumedTranscriber
    )
    try await relaunchedPipeline.resume(
      sessionID: fixture.sessionID,
      configuration: TranscriptionConfiguration()
    )

    let reconciledManifest = try await fixture.fileStore.manifest(
      sessionID: fixture.sessionID
    )
    let reconciledOutputs = reconciledManifest.assets.filter {
      $0.relativePath == "transcripts/raw-v1.json"
        || $0.relativePath == "transcripts/raw-v1.md"
    }
    let resumedCalls = await resumedTranscriber.calledIndices()
    XCTAssertEqual(reconciledManifest.state, .completed)
    XCTAssertEqual(reconciledOutputs, originalOutputs)
    XCTAssertEqual(resumedCalls, [])
  }

  func testResumeMarksSessionForRepairWhenCheckpointChecksumDoesNotMatch()
    async throws
  {
    let fixture = try await makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
    let firstPipeline = makePipeline(
      fixture: fixture,
      transcriber: PipelineFakeTranscriber(mode: .cancel(index: 1))
    )
    do {
      try await firstPipeline.process(
        sessionID: fixture.sessionID,
        jobID: fixture.jobID,
        sourceRelativePath: fixture.sourceRelativePath,
        sourceDuration: 6,
        configuration: TranscriptionConfiguration()
      )
      XCTFail("Fixture must stop with a resumable checkpoint.")
    } catch is CancellationError {
      // Expected.
    }
    let manifest = try await fixture.fileStore.manifest(
      sessionID: fixture.sessionID
    )
    let checkpointAsset = try XCTUnwrap(
      manifest.assets.first { $0.kind == .checkpoint }
    )
    let checkpointURL = try await fixture.fileStore.fileURL(
      sessionID: fixture.sessionID,
      relativePath: checkpointAsset.relativePath
    )
    try Data("corrupt checkpoint".utf8).write(to: checkpointURL)

    let relaunchedPipeline = makePipeline(
      fixture: fixture,
      transcriber: PipelineFakeTranscriber()
    )
    do {
      try await relaunchedPipeline.resume(
        sessionID: fixture.sessionID,
        configuration: TranscriptionConfiguration()
      )
      XCTFail("A mismatched checkpoint must not be resumed.")
    } catch let error as SessionFileStoreError {
      XCTAssertEqual(error, .checksumMismatch)
    }

    let repairedSession = try await fixture.repository.session(
      id: fixture.sessionID
    )
    let failedJob = try await fixture.repository.job(id: fixture.jobID)
    let repairedManifest = try await fixture.fileStore.manifest(
      sessionID: fixture.sessionID
    )
    XCTAssertEqual(repairedSession?.status, .needsRepair)
    XCTAssertTrue(repairedSession?.needsRepair == true)
    XCTAssertEqual(failedJob?.stage, .retryRequired)
    XCTAssertEqual(failedJob?.errorCategory, "sessionIntegrity")
    XCTAssertEqual(repairedManifest.state, .needsRepair)
  }

  func testCancellationDuringExportKeepsRawOutputAndResumesWithoutRetranscribing()
    async throws
  {
    let fixture = try await makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
    let firstTranscriber = PipelineFakeTranscriber()
    let cancellingPipeline = makePipeline(
      fixture: fixture,
      transcriber: firstTranscriber,
      markdownRenderer: PipelineCancellingMarkdownRenderer()
    )

    let task = Task {
      try await cancellingPipeline.process(
        sessionID: fixture.sessionID,
        jobID: fixture.jobID,
        sourceRelativePath: fixture.sourceRelativePath,
        sourceDuration: 6,
        configuration: TranscriptionConfiguration()
      )
    }
    do {
      try await task.value
      XCTFail("Cancellation during export must retain resumable outputs.")
    } catch is CancellationError {
      // Expected.
    }

    let cancelledManifest = try await fixture.fileStore.manifest(
      sessionID: fixture.sessionID
    )
    let cancelledJob = try await fixture.repository.job(id: fixture.jobID)
    XCTAssertNotNil(
      cancelledManifest.assets.first {
        $0.relativePath == "transcripts/raw-v1.json"
      }
    )
    XCTAssertNil(
      cancelledManifest.assets.first {
        $0.relativePath == "transcripts/raw-v1.md"
      }
    )
    XCTAssertEqual(cancelledManifest.state, .ready)
    XCTAssertEqual(cancelledJob?.stage, .cancelled)
    XCTAssertEqual(cancelledJob?.completedChunks, 2)

    let resumedTranscriber = PipelineFakeTranscriber()
    let relaunchedPipeline = makePipeline(
      fixture: fixture,
      transcriber: resumedTranscriber
    )
    try await relaunchedPipeline.resume(
      sessionID: fixture.sessionID,
      configuration: TranscriptionConfiguration()
    )

    let resumedCalls = await resumedTranscriber.calledIndices()
    let completedManifest = try await fixture.fileStore.manifest(
      sessionID: fixture.sessionID
    )
    XCTAssertEqual(resumedCalls, [])
    XCTAssertEqual(completedManifest.state, .completed)
    XCTAssertNotNil(
      completedManifest.assets.first {
        $0.relativePath == "transcripts/raw-v1.md"
      }
    )
  }

  private func makePipeline(
    fixture: PipelineFixture,
    transcriber: PipelineFakeTranscriber,
    markdownRenderer: any RawTranscriptRendering = PipelineMarkdownRenderer()
  ) -> VoiceNoteTranscriptionPipeline {
    let specifications = [
      PipelineChunkSpecification(index: 0, startTime: 0, endTime: 4),
      PipelineChunkSpecification(index: 1, startTime: 2, endTime: 6),
    ]
    return VoiceNoteTranscriptionPipeline(
      repository: fixture.repository,
      fileStore: fixture.fileStore,
      transcriptionEngine: transcriber,
      markdownRenderer: markdownRenderer,
      chunkerFactory: { directory in
        PipelineFakeChunker(
          destinationDirectory: directory,
          specifications: specifications
        )
      },
      now: { Date(timeIntervalSince1970: 1_000) }
    )
  }

  private func makeFixture() async throws -> PipelineFixture {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("SpeakNote-PipelineTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
      at: rootURL,
      withIntermediateDirectories: true
    )
    let fileStore = try SessionFileStore(rootURL: rootURL)
    let repository = SwiftDataSessionRepository(
      modelContainer: try SpeakNoteModelContainer.inMemory()
    )
    let sessionID = UUID()
    let jobID = UUID()
    let sourceRelativePath = "audio/imported-original.m4a"
    _ = try await fileStore.prepareSession(
      id: sessionID,
      source: .imported,
      createdAt: Date(timeIntervalSince1970: 100)
    )
    _ = try await fileStore.write(
      Data(repeating: 7, count: 1_024),
      sessionID: sessionID,
      relativePath: sourceRelativePath,
      kind: .importedOriginal,
      createdAt: Date(timeIntervalSince1970: 100)
    )
    _ = try await repository.createSession(
      NewRecordingSession(
        id: sessionID,
        title: "Voice note",
        createdAt: Date(timeIntervalSince1970: 100),
        source: .imported,
        status: .ready,
        duration: 6
      )
    )
    _ = try await repository.createJob(
      NewTranscriptionJob(
        id: jobID,
        sessionID: sessionID,
        createdAt: Date(timeIntervalSince1970: 100)
      )
    )
    _ = try await repository.updateSession(
      id: sessionID,
      status: .ready,
      duration: 6,
      currentJobID: jobID,
      updatedAt: Date(timeIntervalSince1970: 100)
    )
    return PipelineFixture(
      rootURL: rootURL,
      fileStore: fileStore,
      repository: repository,
      sessionID: sessionID,
      jobID: jobID,
      sourceRelativePath: sourceRelativePath
    )
  }
}

private struct PipelineFixture {
  let rootURL: URL
  let fileStore: SessionFileStore
  let repository: SwiftDataSessionRepository
  let sessionID: UUID
  let jobID: UUID
  let sourceRelativePath: String
}

private struct PipelineChunkSpecification: Sendable {
  let index: Int
  let startTime: TimeInterval
  let endTime: TimeInterval
}

private struct PipelineFakeChunker: AudioChunking {
  let destinationDirectory: URL
  let specifications: [PipelineChunkSpecification]

  func chunks(from sourceURL: URL) async throws -> [AudioChunk] {
    try FileManager.default.createDirectory(
      at: destinationDirectory,
      withIntermediateDirectories: true
    )
    return try specifications.map { specification in
      let data = Data(
        repeating: UInt8(specification.index + 1),
        count: 1_024
      )
      let url = destinationDirectory.appendingPathComponent(
        "\(String(format: "%04d", specification.index)).wav"
      )
      try data.write(to: url)
      return AudioChunk(
        index: specification.index,
        url: url,
        startTime: specification.startTime,
        endTime: specification.endTime,
        byteCount: Int64(data.count),
        sha256: SHA256.hash(data: data)
          .map { String(format: "%02x", $0) }
          .joined()
      )
    }
  }
}

private actor PipelineFakeTranscriber: TranscriptionEngine {
  enum Mode: Sendable {
    case success
    case ambiguous(index: Int)
    case cancel(index: Int)
  }

  private let mode: Mode
  private var calls: [Int] = []
  private var configurations: [TranscriptionConfiguration] = []

  init(mode: Mode = .success) {
    self.mode = mode
  }

  func transcribe(
    audioURL: URL,
    configuration: TranscriptionConfiguration
  ) async throws -> Transcript {
    guard
      let index = Int(
        audioURL.deletingPathExtension().lastPathComponent
      )
    else {
      throw GroqAPIError.invalidAudioFile
    }
    calls.append(index)
    configurations.append(configuration)
    switch mode {
    case .success:
      break
    case .ambiguous(let failureIndex) where index == failureIndex:
      throw GroqAPIError.ambiguousCompletion
    case .cancel(let failureIndex) where index == failureIndex:
      throw CancellationError()
    case .ambiguous, .cancel:
      break
    }
    let text = index == 0 ? "alpha shared" : "shared beta"
    return Transcript(
      text: text,
      segments: [
        TranscriptSegment(
          startTime: 0,
          endTime: 4,
          text: text,
          detectedLanguage: "en"
        )
      ],
      detectedLanguage: "en"
    )
  }

  func calledIndices() -> [Int] {
    calls
  }

  func calledConfigurations() -> [TranscriptionConfiguration] {
    configurations
  }
}

private struct PipelineMarkdownRenderer: RawTranscriptRendering {
  func render(
    session: RecordingSessionDTO,
    transcript: Transcript
  ) -> String {
    "# \(session.title)\n\(transcript.text)\n"
  }
}

private struct PipelineCancellingMarkdownRenderer: RawTranscriptRendering {
  func render(
    session: RecordingSessionDTO,
    transcript: Transcript
  ) -> String {
    withUnsafeCurrentTask { task in
      task?.cancel()
    }
    return "# \(session.title)\n\(transcript.text)\n"
  }
}
