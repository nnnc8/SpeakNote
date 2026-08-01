import CryptoKit
import Foundation
import XCTest

@testable import SpeakNote

final class VoiceNoteRecordingWorkflowTests: XCTestCase {
  func testStartCreatesDurableSessionAndRecordingJournal() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

    let sessionID = try await fixture.workflow.start(title: "Lecture")

    let session = try await fixture.repository.session(id: sessionID)
    let journal = try await fixture.fileStore.recordingJournal()
    let startedSessionID = await fixture.recorder.startedSessionID
    let startedDirectory = await fixture.recorder.startedDirectory
    XCTAssertEqual(session?.title, "Lecture")
    XCTAssertEqual(session?.source, .recorded)
    XCTAssertEqual(session?.status, .recording)
    XCTAssertEqual(journal?.sessionID, sessionID)
    XCTAssertEqual(journal?.state, .recording)
    XCTAssertEqual(startedSessionID, sessionID)
    XCTAssertEqual(startedDirectory?.lastPathComponent, "audio")
  }

  func testClosedSegmentIsChecksummedIntoManifestAndJournal() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
    let sessionID = try await fixture.workflow.start(title: nil)

    _ = try await fixture.recorder.closeSegment(index: 0, endTime: 12)
    let committed = await eventually {
      guard let session = try? await fixture.repository.session(id: sessionID)
      else {
        return false
      }
      return session.duration == 12
    }

    let manifest = try await fixture.fileStore.manifest(sessionID: sessionID)
    let journal = try await fixture.fileStore.recordingJournal()
    XCTAssertTrue(committed)
    XCTAssertEqual(
      manifest.assets.filter { $0.kind == .captureSegment }.count,
      1
    )
    XCTAssertEqual(journal?.lastClosedSegmentIndex, 0)
  }

  func testPauseResumeAndStopBuildArchiveThenStartProcessing() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
    let sessionID = try await fixture.workflow.start(title: "Meeting")
    let segment = try await fixture.recorder.closeSegment(index: 0, endTime: 8)
    _ = await eventually {
      let journal = try? await fixture.fileStore.recordingJournal()
      return journal?.lastClosedSegmentIndex == 0
    }

    try await fixture.workflow.pause()
    var session = try await fixture.repository.session(id: sessionID)
    var journal = try await fixture.fileStore.recordingJournal()
    XCTAssertEqual(session?.status, .paused)
    XCTAssertEqual(journal?.state, .paused)

    try await fixture.workflow.resume()
    session = try await fixture.repository.session(id: sessionID)
    journal = try await fixture.fileStore.recordingJournal()
    XCTAssertEqual(session?.status, .recording)
    XCTAssertEqual(journal?.state, .recording)

    try await fixture.workflow.stopAndProcess()

    let manifest = try await fixture.fileStore.manifest(sessionID: sessionID)
    let clearedJournal = try await fixture.fileStore.recordingJournal()
    let processingRequests = await fixture.processingStarter.requests
    XCTAssertNil(clearedJournal)
    XCTAssertEqual(manifest.assets.filter { $0.kind == .archive }.count, 1)
    XCTAssertEqual(
      manifest.assets.filter { $0.kind == .captureSegment }.count,
      0
    )
    XCTAssertFalse(FileManager.default.fileExists(atPath: segment.url.path))
    XCTAssertEqual(processingRequests.map(\.sessionID), [sessionID])
    XCTAssertEqual(
      processingRequests.map(\.sourceRelativePath),
      ["audio/archive.m4a"]
    )
    XCTAssertEqual(processingRequests.map(\.duration), [8])
  }

  func testCancelPreservesClosedSegmentsAndOffersRecovery() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
    let sessionID = try await fixture.workflow.start(title: nil)
    _ = try await fixture.recorder.closeSegment(index: 0, endTime: 5)
    _ = await eventually {
      let journal = try? await fixture.fileStore.recordingJournal()
      return journal?.lastClosedSegmentIndex == 0
    }

    await fixture.workflow.cancelPreservingAudio()

    let session = try await fixture.repository.session(id: sessionID)
    let manifest = try await fixture.fileStore.manifest(sessionID: sessionID)
    let journal = try await fixture.fileStore.recordingJournal()
    let interruptionReasons = await fixture.recorder.interruptionReasons
    XCTAssertEqual(session?.status, .recoveryAvailable)
    XCTAssertEqual(manifest.state, .interrupted)
    XCTAssertEqual(journal?.state, .interrupted)
    XCTAssertEqual(interruptionReasons, [.userRequested])
    XCTAssertEqual(
      manifest.assets.filter { $0.kind == .captureSegment }.count,
      1
    )
  }

  func testRecoveryResumesAfterArchiveManifestCrashWindow() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
    let sessionID = try await fixture.workflow.start(title: "Recovered")
    let segment = try await fixture.recorder.closeSegment(index: 0, endTime: 5)
    _ = await eventually {
      let journal = try? await fixture.fileStore.recordingJournal()
      return journal?.lastClosedSegmentIndex == 0
    }
    await fixture.workflow.cancelPreservingAudio()
    let archiveData = Data(repeating: 7, count: 1_024)
    _ = try await fixture.fileStore.write(
      archiveData,
      sessionID: sessionID,
      relativePath: "audio/archive.m4a",
      kind: .archive
    )
    let storedSession = try await fixture.repository.session(id: sessionID)
    let session = try XCTUnwrap(storedSession)
    await fixture.recoveryManager.setCandidate(
      VoiceNoteRecoveryCandidate(
        session: session,
        completeSegments: [segment],
        incompleteCurrentSegment: nil,
        issues: []
      )
    )

    try await fixture.workflow.recoverAndProcess(sessionID: sessionID)

    let manifest = try await fixture.fileStore.manifest(sessionID: sessionID)
    let requests = await fixture.processingStarter.requests
    XCTAssertEqual(manifest.assets.filter { $0.kind == .archive }.count, 1)
    XCTAssertEqual(
      manifest.assets.filter { $0.kind == .captureSegment }.count,
      0
    )
    XCTAssertFalse(FileManager.default.fileExists(atPath: segment.url.path))
    XCTAssertEqual(requests.map(\.sessionID), [sessionID])
  }

  func testDeviceLossMarksSessionRecoverableWithoutDiscardingClosedAudio() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
    let sessionID = try await fixture.workflow.start(title: nil)
    _ = try await fixture.recorder.closeSegment(index: 0, endTime: 4)
    _ = await eventually {
      let journal = try? await fixture.fileStore.recordingJournal()
      return journal?.lastClosedSegmentIndex == 0
    }

    await fixture.recorder.loseDevice()
    let recovered = await eventually {
      let session = try? await fixture.repository.session(id: sessionID)
      return session?.status == .recoveryAvailable
    }

    let manifest = try await fixture.fileStore.manifest(sessionID: sessionID)
    XCTAssertTrue(recovered)
    XCTAssertEqual(manifest.state, .interrupted)
    XCTAssertEqual(
      manifest.assets.filter { $0.kind == .captureSegment }.count,
      1
    )
  }

  func testLowDiskPreflightFailsBeforeRecorderStartsAndCleansMetadata()
    async throws
  {
    let diskCapacity = RecordingWorkflowFakeDiskCapacityChecker(capacity: 9)
    let fixture = try makeFixture(
      diskCapacityChecker: diskCapacity,
      minimumAvailableDiskCapacityBytes: 10
    )
    defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

    do {
      _ = try await fixture.workflow.start(title: nil)
      XCTFail("Low disk capacity must fail before capture starts.")
    } catch {
      XCTAssertEqual(
        error as? VoiceNoteRecordingWorkflowError,
        .insufficientDiskSpace
      )
    }

    let sessions = try await fixture.repository.sessions()
    let startedSessionID = await fixture.recorder.startedSessionID
    XCTAssertTrue(sessions.isEmpty)
    XCTAssertNil(startedSessionID)
  }

  func testLowDiskDuringRecordingStopsAndPreservesCommittedAudio()
    async throws
  {
    let diskCapacity = RecordingWorkflowFakeDiskCapacityChecker(capacity: 100)
    let fixture = try makeFixture(
      diskCapacityChecker: diskCapacity,
      minimumAvailableDiskCapacityBytes: 10,
      journalInterval: 0.05
    )
    defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
    let sessionID = try await fixture.workflow.start(title: nil)
    _ = try await fixture.recorder.closeSegment(index: 0, endTime: 5)
    let committed = await eventually {
      let manifest = try? await fixture.fileStore.manifest(
        sessionID: sessionID
      )
      return manifest?.assets.contains(where: {
        $0.kind == .captureSegment
      }) == true
    }
    XCTAssertTrue(committed)

    await diskCapacity.setCapacity(0)
    let preserved = await eventually {
      let session = try? await fixture.repository.session(id: sessionID)
      return session?.status == .recoveryAvailable
    }

    let manifest = try await fixture.fileStore.manifest(sessionID: sessionID)
    let interruptionReasons = await fixture.recorder.interruptionReasons
    XCTAssertTrue(preserved)
    XCTAssertEqual(manifest.state, .interrupted)
    XCTAssertEqual(interruptionReasons, [.systemInterruption])
    XCTAssertEqual(
      manifest.assets.filter { $0.kind == .captureSegment }.count,
      1
    )
  }

  private func makeFixture(
    diskCapacityChecker: any DiskCapacityChecking =
      RecordingWorkflowFakeDiskCapacityChecker(capacity: .max),
    minimumAvailableDiskCapacityBytes: Int64 = 10,
    journalInterval: TimeInterval = 100
  ) throws -> RecordingWorkflowFixture {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "SpeakNote-RecordingWorkflowTests-\(UUID().uuidString)"
      )
    try FileManager.default.createDirectory(
      at: rootURL,
      withIntermediateDirectories: true
    )
    let fileStore = try SessionFileStore(rootURL: rootURL)
    let repository = SwiftDataSessionRepository(
      modelContainer: try SpeakNoteModelContainer.inMemory()
    )
    let recorder = RecordingWorkflowFakeRecorder()
    let processingStarter = RecordingWorkflowFakeProcessingStarter()
    let recoveryManager = RecordingWorkflowFakeRecoveryManager()
    let workflow = VoiceNoteRecordingWorkflow(
      repository: repository,
      fileStore: fileStore,
      recorder: recorder,
      archiveBuilder: RecordingWorkflowFakeArchiveBuilder(),
      processingStarter: processingStarter,
      recoveryManager: recoveryManager,
      diskCapacityChecker: diskCapacityChecker,
      minimumAvailableDiskCapacityBytes: minimumAvailableDiskCapacityBytes,
      journalInterval: journalInterval,
      now: { Date(timeIntervalSince1970: 100) }
    )
    return RecordingWorkflowFixture(
      rootURL: rootURL,
      fileStore: fileStore,
      repository: repository,
      recorder: recorder,
      processingStarter: processingStarter,
      recoveryManager: recoveryManager,
      workflow: workflow
    )
  }

  private func eventually(
    _ condition: @escaping @Sendable () async -> Bool
  ) async -> Bool {
    for _ in 0..<100 {
      if await condition() {
        return true
      }
      try? await Task.sleep(for: .milliseconds(10))
    }
    return false
  }
}

private actor RecordingWorkflowFakeDiskCapacityChecker:
  DiskCapacityChecking
{
  private var capacity: Int64

  init(capacity: Int64) {
    self.capacity = capacity
  }

  func availableCapacity(at url: URL) -> Int64 {
    capacity
  }

  func setCapacity(_ capacity: Int64) {
    self.capacity = capacity
  }
}

private struct RecordingWorkflowFixture {
  let rootURL: URL
  let fileStore: SessionFileStore
  let repository: SwiftDataSessionRepository
  let recorder: RecordingWorkflowFakeRecorder
  let processingStarter: RecordingWorkflowFakeProcessingStarter
  let recoveryManager: RecordingWorkflowFakeRecoveryManager
  let workflow: VoiceNoteRecordingWorkflow
}

private actor RecordingWorkflowFakeRecorder: M4RollingSegmentRecording {
  nonisolated let events: AsyncStream<M4RollingRecorderEvent>

  private let continuation: AsyncStream<M4RollingRecorderEvent>.Continuation
  private(set) var startedSessionID: UUID?
  private(set) var startedDirectory: URL?
  private(set) var interruptionReasons: [M4RecordingInterruptionReason] = []
  private var segments: [M4RecordingSegment] = []
  private var state: M4RollingRecorderState = .idle

  init() {
    let stream = AsyncStream<M4RollingRecorderEvent>.makeStream()
    events = stream.stream
    continuation = stream.continuation
  }

  func currentState() -> M4RollingRecorderState {
    state
  }

  func start(sessionID: UUID, directory: URL) {
    startedSessionID = sessionID
    startedDirectory = directory
    state = .recording(
      sessionID: sessionID,
      startedAt: Date(timeIntervalSince1970: 100)
    )
  }

  func pause() throws {
    guard let sessionID = startedSessionID else {
      throw M4RollingRecorderFailure.invalidState
    }
    state = .paused(
      sessionID: sessionID,
      startedAt: Date(timeIntervalSince1970: 100)
    )
  }

  func resume() throws {
    guard let sessionID = startedSessionID else {
      throw M4RollingRecorderFailure.invalidState
    }
    state = .recording(
      sessionID: sessionID,
      startedAt: Date(timeIntervalSince1970: 100)
    )
  }

  func stop() throws -> M4RollingRecordingResult {
    guard let sessionID = startedSessionID else {
      throw M4RollingRecorderFailure.invalidState
    }
    state = .idle
    return M4RollingRecordingResult(
      sessionID: sessionID,
      segments: segments
    )
  }

  func cancel() {
    state = .idle
  }

  func interrupt(reason: M4RecordingInterruptionReason) {
    interruptionReasons.append(reason)
    if let sessionID = startedSessionID {
      state = .interrupted(sessionID: sessionID, reason: reason)
    }
  }

  func closeSegment(
    index: Int,
    endTime: TimeInterval
  ) throws -> M4RecordingSegment {
    guard let sessionID = startedSessionID, let directory = startedDirectory else {
      throw M4RollingRecorderFailure.invalidState
    }
    let url = directory.appendingPathComponent(
      String(format: "capture-%06d.caf", index)
    )
    let data = Data(repeating: UInt8(index + 1), count: 2_048)
    try data.write(to: url)
    let segment = M4RecordingSegment(
      sessionID: sessionID,
      index: index,
      url: url,
      relativePath: url.lastPathComponent,
      startTime: segments.last?.endTime ?? 0,
      endTime: endTime,
      byteCount: Int64(data.count),
      sha256: SHA256.hash(data: data)
        .map { String(format: "%02x", $0) }
        .joined(),
      createdAt: Date(timeIntervalSince1970: 100 + Double(index))
    )
    segments.append(segment)
    continuation.yield(.segmentClosed(segment))
    return segment
  }

  func loseDevice() {
    guard let sessionID = startedSessionID else { return }
    state = .interrupted(sessionID: sessionID, reason: .deviceLost)
    continuation.yield(.stateChanged(state))
  }
}

private struct RecordingWorkflowFakeArchiveBuilder: M4AudioArchiving {
  func buildArchive(
    segments: [M4RecordingSegment],
    destinationURL: URL
  ) async throws -> M4AudioArchive {
    let data = Data(repeating: 9, count: 4_096)
    try data.write(to: destinationURL)
    return M4AudioArchive(
      url: destinationURL,
      duration: segments.last?.endTime ?? 0,
      byteCount: Int64(data.count),
      sha256: SHA256.hash(data: data)
        .map { String(format: "%02x", $0) }
        .joined()
    )
  }
}

private actor RecordingWorkflowFakeProcessingStarter:
  VoiceNoteRecordedProcessingStarting
{
  struct Request: Equatable, Sendable {
    let sessionID: UUID
    let sourceRelativePath: String
    let duration: TimeInterval
  }

  private(set) var requests: [Request] = []

  func startRecordedProcessing(
    sessionID: UUID,
    sourceRelativePath: String,
    duration: TimeInterval
  ) {
    requests.append(
      Request(
        sessionID: sessionID,
        sourceRelativePath: sourceRelativePath,
        duration: duration
      )
    )
  }
}

private actor RecordingWorkflowFakeRecoveryManager: VoiceNoteRecoveryManaging {
  var candidates: [UUID: VoiceNoteRecoveryCandidate] = [:]

  func setCandidate(_ candidate: VoiceNoteRecoveryCandidate) {
    candidates[candidate.id] = candidate
  }

  func reconcile() -> [VoiceNoteRecoveryCandidate] {
    Array(candidates.values)
  }

  func candidate(sessionID: UUID) throws -> VoiceNoteRecoveryCandidate {
    guard let candidate = candidates[sessionID] else {
      throw VoiceNoteRecoveryError.sessionNotFound
    }
    return candidate
  }

  func keepAudio(sessionID: UUID) throws {
    guard candidates[sessionID] != nil else {
      throw VoiceNoteRecoveryError.sessionNotFound
    }
  }

  func playbackSegments(sessionID: UUID) throws -> [M4RecordingSegment] {
    guard let candidate = candidates[sessionID] else {
      throw VoiceNoteRecoveryError.sessionNotFound
    }
    return candidate.completeSegments
  }
}
