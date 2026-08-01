import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Foundation

public struct InsertionTarget: Sendable, Equatable {
  public let processIdentifier: pid_t
  public let bundleIdentifier: String?

  public init(processIdentifier: pid_t, bundleIdentifier: String?) {
    self.processIdentifier = processIdentifier
    self.bundleIdentifier = bundleIdentifier
  }
}

public enum TextInsertionFallbackReason: Sendable, Equatable {
  case targetChanged
  case postEventPermissionMissing
  case secureInputEnabled
  case pasteboardNotPreservable
  case pasteCommandUnavailable
}

public enum TextInsertionResult: Sendable, Equatable {
  case inserted
  case manualCopyRequired(TextInsertionFallbackReason)
}

public enum TextInsertionError: Error, Sendable, Equatable {
  case noFrontmostApplication
  case pasteboardRestoreFailed
}

@MainActor
public protocol TextInserting: AnyObject {
  func captureTarget() throws -> InsertionTarget
  func insert(_ text: String, into target: InsertionTarget) async throws -> TextInsertionResult
}

struct PasteboardSnapshot: Sendable, Equatable {
  struct Item: Sendable, Equatable {
    let values: [String: Data]
  }

  let items: [Item]
}

@MainActor
protocol FrontmostApplicationProviding: AnyObject {
  var target: InsertionTarget? { get }
}

@MainActor
protocol PasteboardAccessing: AnyObject {
  var changeCount: Int { get }
  func snapshot(maximumBytes: Int) throws -> PasteboardSnapshot
  func write(text: String, ownershipToken: String) -> Bool
  func owns(token: String, changeCount: Int) -> Bool
  func restore(_ snapshot: PasteboardSnapshot) -> Bool
}

@MainActor
protocol PasteCommandPosting: AnyObject {
  var canPostEvents: Bool { get }
  var secureInputEnabled: Bool { get }
  func postPaste(to processIdentifier: pid_t) -> Bool
}

@MainActor
protocol ManualTextCopying: AnyObject {
  func copy(_ text: String) -> Bool
}

@MainActor
final class WorkspaceFrontmostApplicationProvider: FrontmostApplicationProviding {
  var target: InsertionTarget? {
    guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
    return InsertionTarget(
      processIdentifier: app.processIdentifier,
      bundleIdentifier: app.bundleIdentifier
    )
  }
}

@MainActor
final class SystemPasteCommandPoster: PasteCommandPosting {
  var canPostEvents: Bool { CGPreflightPostEventAccess() }
  var secureInputEnabled: Bool { IsSecureEventInputEnabled() }

  func postPaste(to processIdentifier: pid_t) -> Bool {
    guard let source = CGEventSource(stateID: .hidSystemState),
      let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
      let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
    else {
      return false
    }
    down.flags = .maskCommand
    up.flags = .maskCommand
    down.postToPid(processIdentifier)
    up.postToPid(processIdentifier)
    return true
  }
}

@MainActor
final class SystemPasteboard: PasteboardAccessing {
  static let ownershipType = NSPasteboard.PasteboardType("com.nc8.SpeakNote.pasteboard-owner")
  private let pasteboard: NSPasteboard

  init(pasteboard: NSPasteboard = .general) {
    self.pasteboard = pasteboard
  }

  var changeCount: Int { pasteboard.changeCount }

  func snapshot(maximumBytes: Int) throws -> PasteboardSnapshot {
    var remaining = maximumBytes
    var copiedItems: [PasteboardSnapshot.Item] = []
    for item in pasteboard.pasteboardItems ?? [] {
      var values: [String: Data] = [:]
      for type in item.types {
        guard let data = item.data(forType: type), data.count <= remaining else {
          throw SnapshotError.notPreservable
        }
        remaining -= data.count
        values[type.rawValue] = Data(data)
      }
      copiedItems.append(.init(values: values))
    }
    return PasteboardSnapshot(items: copiedItems)
  }

  func write(text: String, ownershipToken: String) -> Bool {
    let item = NSPasteboardItem()
    guard item.setString(text, forType: .string),
      item.setString(ownershipToken, forType: Self.ownershipType)
    else {
      return false
    }
    pasteboard.clearContents()
    return pasteboard.writeObjects([item])
  }

  func owns(token: String, changeCount: Int) -> Bool {
    pasteboard.changeCount == changeCount
      && pasteboard.string(forType: Self.ownershipType) == token
  }

  func restore(_ snapshot: PasteboardSnapshot) -> Bool {
    pasteboard.clearContents()
    guard !snapshot.items.isEmpty else { return true }
    let items = snapshot.items.map { saved -> NSPasteboardItem in
      let item = NSPasteboardItem()
      for (rawType, data) in saved.values {
        item.setData(data, forType: NSPasteboard.PasteboardType(rawType))
      }
      return item
    }
    return pasteboard.writeObjects(items)
  }

  private enum SnapshotError: Error {
    case notPreservable
  }
}

@MainActor
final class SystemManualTextCopier: ManualTextCopying {
  private let pasteboard: NSPasteboard

  init(pasteboard: NSPasteboard = .general) {
    self.pasteboard = pasteboard
  }

  func copy(_ text: String) -> Bool {
    pasteboard.clearContents()
    return pasteboard.setString(text, forType: .string)
  }
}

@MainActor
public final class TextInsertionService: TextInserting {
  public static let maximumPasteboardSnapshotBytes = 32 * 1024 * 1024

  private let applications: any FrontmostApplicationProviding
  private let pasteboard: any PasteboardAccessing
  private let commandPoster: any PasteCommandPosting
  private let restoreDelay: @MainActor @Sendable () async throws -> Void

  public convenience init() {
    self.init(
      applications: WorkspaceFrontmostApplicationProvider(),
      pasteboard: SystemPasteboard(),
      commandPoster: SystemPasteCommandPoster()
    )
  }

  init(
    applications: any FrontmostApplicationProviding,
    pasteboard: any PasteboardAccessing,
    commandPoster: any PasteCommandPosting,
    restoreDelay: @escaping @MainActor @Sendable () async throws -> Void = {
      try await Task.sleep(for: .milliseconds(200))
    }
  ) {
    self.applications = applications
    self.pasteboard = pasteboard
    self.commandPoster = commandPoster
    self.restoreDelay = restoreDelay
  }

  public func captureTarget() throws -> InsertionTarget {
    guard let target = applications.target else {
      throw TextInsertionError.noFrontmostApplication
    }
    return target
  }

  public func insert(_ text: String, into target: InsertionTarget) async throws
    -> TextInsertionResult
  {
    guard targetMatches(target) else {
      return .manualCopyRequired(.targetChanged)
    }
    guard commandPoster.canPostEvents else {
      return .manualCopyRequired(.postEventPermissionMissing)
    }
    guard !commandPoster.secureInputEnabled else {
      return .manualCopyRequired(.secureInputEnabled)
    }
    let snapshot: PasteboardSnapshot
    do {
      snapshot = try pasteboard.snapshot(maximumBytes: Self.maximumPasteboardSnapshotBytes)
    } catch {
      return .manualCopyRequired(.pasteboardNotPreservable)
    }

    let token = UUID().uuidString
    guard pasteboard.write(text: text, ownershipToken: token) else {
      guard pasteboard.restore(snapshot) else { throw TextInsertionError.pasteboardRestoreFailed }
      return .manualCopyRequired(.pasteboardNotPreservable)
    }
    let ownedChangeCount = pasteboard.changeCount

    guard targetMatches(target) else {
      try restoreIfOwned(snapshot, token: token, changeCount: ownedChangeCount)
      return .manualCopyRequired(.targetChanged)
    }
    guard commandPoster.canPostEvents else {
      try restoreIfOwned(snapshot, token: token, changeCount: ownedChangeCount)
      return .manualCopyRequired(.postEventPermissionMissing)
    }
    guard !commandPoster.secureInputEnabled else {
      try restoreIfOwned(snapshot, token: token, changeCount: ownedChangeCount)
      return .manualCopyRequired(.secureInputEnabled)
    }
    guard commandPoster.postPaste(to: target.processIdentifier) else {
      try restoreIfOwned(snapshot, token: token, changeCount: ownedChangeCount)
      return .manualCopyRequired(.pasteCommandUnavailable)
    }

    do {
      try await restoreDelay()
    } catch {
      try restoreIfOwned(snapshot, token: token, changeCount: ownedChangeCount)
      throw error
    }
    try restoreIfOwned(snapshot, token: token, changeCount: ownedChangeCount)
    return .inserted
  }

  private func targetMatches(_ target: InsertionTarget) -> Bool {
    guard let current = applications.target,
      current.processIdentifier == target.processIdentifier
    else {
      return false
    }
    if let expectedBundle = target.bundleIdentifier {
      return current.bundleIdentifier == expectedBundle
    }
    return true
  }

  private func restoreIfOwned(
    _ snapshot: PasteboardSnapshot,
    token: String,
    changeCount: Int
  ) throws {
    guard pasteboard.owns(token: token, changeCount: changeCount) else { return }
    guard pasteboard.restore(snapshot) else {
      throw TextInsertionError.pasteboardRestoreFailed
    }
  }
}
