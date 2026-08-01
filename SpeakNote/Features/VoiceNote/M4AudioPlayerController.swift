@preconcurrency import AVFoundation
import Combine
import Foundation

enum M4AudioPlayerError: Error, Equatable, Sendable {
  case emptySegments
  case mismatchedSession
  case noncontiguousSegments
  case missingFile(index: Int)
  case invalidDuration(index: Int)
  case notLoaded
  case invalidSeekTime
}

enum M4AudioPlayerState: Equatable, Sendable {
  case idle
  case ready
  case playing
  case paused
  case stopped
  case completed
  case failed(M4AudioPlayerError)
}

enum M4AudioPlaybackEvent: Equatable, Sendable {
  case position(segmentIndex: Int, time: TimeInterval)
  case completed
}

@MainActor
protocol M4AudioPlaybackBackend: AnyObject {
  var eventHandler: ((M4AudioPlaybackEvent) -> Void)? { get set }

  func load(urls: [URL])
  func play()
  func pause()
  func stop()
  func seek(toSegment index: Int, time: TimeInterval)
}

@MainActor
final class M4AudioPlayerController: ObservableObject {
  @Published private(set) var state: M4AudioPlayerState = .idle
  @Published private(set) var progress: TimeInterval = 0
  @Published private(set) var duration: TimeInterval = 0

  private struct TimelineSegment {
    let offset: TimeInterval
    let duration: TimeInterval
  }

  private let backend: any M4AudioPlaybackBackend
  private var timeline: [TimelineSegment] = []

  init(
    backend: any M4AudioPlaybackBackend = M4AVFoundationAudioPlaybackBackend()
  ) {
    self.backend = backend
    backend.eventHandler = { [weak self] event in
      self?.handle(event)
    }
  }

  func load(segments: [M4RecordingSegment]) throws {
    do {
      let ordered = try Self.validatedSegments(segments)
      var offset: TimeInterval = 0
      timeline = ordered.map { segment in
        let segmentDuration = segment.endTime - segment.startTime
        defer { offset += segmentDuration }
        return TimelineSegment(offset: offset, duration: segmentDuration)
      }
      duration = offset
      progress = 0
      backend.load(urls: ordered.map(\.url))
      state = .ready
    } catch let error as M4AudioPlayerError {
      timeline = []
      duration = 0
      progress = 0
      state = .failed(error)
      throw error
    }
  }

  func play() throws {
    guard !timeline.isEmpty else {
      throw M4AudioPlayerError.notLoaded
    }
    if state == .completed {
      backend.seek(toSegment: 0, time: 0)
      progress = 0
    }
    backend.play()
    state = .playing
  }

  func pause() {
    guard state == .playing else { return }
    backend.pause()
    state = .paused
  }

  func stop() {
    guard !timeline.isEmpty else { return }
    backend.stop()
    progress = 0
    state = .stopped
  }

  func seek(to time: TimeInterval) throws {
    guard !timeline.isEmpty else {
      throw M4AudioPlayerError.notLoaded
    }
    guard time.isFinite else {
      throw M4AudioPlayerError.invalidSeekTime
    }
    let target = min(max(0, time), duration)
    let mapping = timelineMapping(for: target)
    let wasPlaying = state == .playing
    backend.seek(toSegment: mapping.index, time: mapping.localTime)
    progress = target
    if state == .completed {
      state = .paused
    }
    if wasPlaying {
      backend.play()
    }
  }

  private func timelineMapping(
    for time: TimeInterval
  ) -> (index: Int, localTime: TimeInterval) {
    if time >= duration, let last = timeline.last {
      return (timeline.count - 1, last.duration)
    }
    for (index, segment) in timeline.enumerated()
    where time < segment.offset + segment.duration {
      return (index, time - segment.offset)
    }
    return (0, 0)
  }

  private func handle(_ event: M4AudioPlaybackEvent) {
    switch event {
    case .position(let index, let localTime):
      guard timeline.indices.contains(index),
        localTime.isFinite
      else {
        return
      }
      let segment = timeline[index]
      progress = min(
        duration,
        segment.offset + min(max(0, localTime), segment.duration)
      )
    case .completed:
      progress = duration
      state = .completed
    }
  }

  private static func validatedSegments(
    _ segments: [M4RecordingSegment]
  ) throws -> [M4RecordingSegment] {
    guard !segments.isEmpty else {
      throw M4AudioPlayerError.emptySegments
    }
    let ordered = segments.sorted { $0.index < $1.index }
    guard ordered.allSatisfy({ $0.sessionID == ordered[0].sessionID }) else {
      throw M4AudioPlayerError.mismatchedSession
    }
    guard ordered.map(\.index) == Array(0..<ordered.count) else {
      throw M4AudioPlayerError.noncontiguousSegments
    }
    for segment in ordered {
      let segmentDuration = segment.endTime - segment.startTime
      guard segmentDuration.isFinite, segmentDuration > 0 else {
        throw M4AudioPlayerError.invalidDuration(index: segment.index)
      }
      var isDirectory: ObjCBool = false
      guard segment.url.isFileURL,
        FileManager.default.fileExists(
          atPath: segment.url.path,
          isDirectory: &isDirectory
        ),
        !isDirectory.boolValue
      else {
        throw M4AudioPlayerError.missingFile(index: segment.index)
      }
    }
    return ordered
  }
}

@MainActor
final class M4AVFoundationAudioPlaybackBackend: NSObject, M4AudioPlaybackBackend {
  var eventHandler: ((M4AudioPlaybackEvent) -> Void)?

  private let player: AVQueuePlayer
  private var urls: [URL] = []
  private var items: [AVPlayerItem] = []
  private var baseIndex = 0
  private var timeObserver: Any?

  init(player: AVQueuePlayer = AVQueuePlayer()) {
    self.player = player
    super.init()
    timeObserver = player.addPeriodicTimeObserver(
      forInterval: CMTime(seconds: 0.1, preferredTimescale: 600),
      queue: .main
    ) { [weak self] time in
      MainActor.assumeIsolated {
        self?.reportPosition(time)
      }
    }
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(itemDidFinishNotification(_:)),
      name: .AVPlayerItemDidPlayToEndTime,
      object: nil
    )
  }

  isolated deinit {
    if let timeObserver {
      player.removeTimeObserver(timeObserver)
    }
    NotificationCenter.default.removeObserver(self)
  }

  func load(urls: [URL]) {
    self.urls = urls
    rebuildQueue(startingAt: 0, time: 0)
  }

  func play() {
    player.play()
  }

  func pause() {
    player.pause()
  }

  func stop() {
    player.pause()
    rebuildQueue(startingAt: 0, time: 0)
  }

  func seek(toSegment index: Int, time: TimeInterval) {
    guard urls.indices.contains(index) else { return }
    let wasPlaying = player.rate != 0
    rebuildQueue(startingAt: index, time: time)
    if wasPlaying {
      player.play()
    }
  }

  private func rebuildQueue(startingAt index: Int, time: TimeInterval) {
    player.removeAllItems()
    guard urls.indices.contains(index) else {
      items = []
      baseIndex = 0
      return
    }
    baseIndex = index
    items = urls[index...].map(AVPlayerItem.init(url:))
    for item in items {
      player.insert(item, after: nil)
    }
    player.seek(
      to: CMTime(seconds: max(0, time), preferredTimescale: 600),
      toleranceBefore: .zero,
      toleranceAfter: .zero
    )
  }

  private func reportPosition(_ time: CMTime) {
    guard let currentItem = player.currentItem,
      let localIndex = items.firstIndex(where: { $0 === currentItem })
    else {
      return
    }
    eventHandler?(
      .position(
        segmentIndex: baseIndex + localIndex,
        time: time.seconds
      )
    )
  }

  private func itemDidFinish(_ item: AVPlayerItem?) {
    guard let item,
      let localIndex = items.firstIndex(where: { $0 === item }),
      baseIndex + localIndex == urls.count - 1
    else {
      return
    }
    eventHandler?(.completed)
  }

  @objc private func itemDidFinishNotification(_ notification: Notification) {
    itemDidFinish(notification.object as? AVPlayerItem)
  }
}
