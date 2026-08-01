import AppKit
import Foundation
import XCTest

@testable import SpeakNote

@MainActor
final class PasteboardInsertionTests: XCTestCase {
  func testDispatchesPasteThenRestoresOnlyWhileStillOwner() async throws {
    let target = InsertionTarget(processIdentifier: 123, bundleIdentifier: "com.apple.TextEdit")
    let apps = FakeApplications(target: target)
    let original = PasteboardSnapshot(items: [
      .init(values: ["public.utf8-plain-text": Data("old".utf8)]),
      .init(values: ["public.png": Data([1, 2, 3])]),
    ])
    let pasteboard = FakePasteboard(snapshot: original)
    let poster = FakeCommandPoster()
    let service = TextInsertionService(
      applications: apps,
      pasteboard: pasteboard,
      commandPoster: poster,
      restoreDelay: {}
    )

    let firstResult = try await service.insert("new", into: target)
    XCTAssertEqual(firstResult, .inserted)
    XCTAssertEqual(poster.postedPIDs, [123])
    XCTAssertEqual(pasteboard.restored, original)

    let userOwnedPasteboard = FakePasteboard(snapshot: original)
    let second = TextInsertionService(
      applications: apps,
      pasteboard: userOwnedPasteboard,
      commandPoster: poster,
      restoreDelay: { userOwnedPasteboard.simulateUserCopy() }
    )
    let secondResult = try await second.insert("new", into: target)
    XCTAssertEqual(secondResult, .inserted)
    XCTAssertNil(userOwnedPasteboard.restored)
  }

  func testFailsClosedBeforeMutatingForChangedTargetSecureInputAndOversizeSnapshot() async throws {
    let target = InsertionTarget(processIdentifier: 123, bundleIdentifier: "com.apple.TextEdit")
    let changedApps = FakeApplications(
      target: InsertionTarget(processIdentifier: 456, bundleIdentifier: "com.apple.Terminal")
    )
    let pasteboard = FakePasteboard(snapshot: .init(items: []))
    let poster = FakeCommandPoster()
    let changedService = TextInsertionService(
      applications: changedApps,
      pasteboard: pasteboard,
      commandPoster: poster
    )
    let changedResult = try await changedService.insert("text", into: target)
    XCTAssertEqual(changedResult, .manualCopyRequired(.targetChanged))
    XCTAssertEqual(pasteboard.writeCount, 0)

    let apps = FakeApplications(target: target)
    poster.secureInputEnabled = true
    let secureService = TextInsertionService(
      applications: apps,
      pasteboard: pasteboard,
      commandPoster: poster
    )
    let secureResult = try await secureService.insert("text", into: target)
    XCTAssertEqual(secureResult, .manualCopyRequired(.secureInputEnabled))
    XCTAssertEqual(pasteboard.writeCount, 0)

    poster.secureInputEnabled = false
    pasteboard.snapshotFails = true
    let oversizedService = TextInsertionService(
      applications: apps,
      pasteboard: pasteboard,
      commandPoster: poster
    )
    let oversizedResult = try await oversizedService.insert("text", into: target)
    XCTAssertEqual(oversizedResult, .manualCopyRequired(.pasteboardNotPreservable))
    XCTAssertEqual(pasteboard.writeCount, 0)
  }

  func testCancellationDuringPasteDelayRestoresClipboardWhenStillOwned() async throws {
    let target = InsertionTarget(
      processIdentifier: 123,
      bundleIdentifier: "com.apple.TextEdit"
    )
    let original = PasteboardSnapshot(items: [
      .init(values: ["public.utf8-plain-text": Data("old".utf8)])
    ])
    let pasteboard = FakePasteboard(snapshot: original)
    let service = TextInsertionService(
      applications: FakeApplications(target: target),
      pasteboard: pasteboard,
      commandPoster: FakeCommandPoster(),
      restoreDelay: { throw CancellationError() }
    )

    do {
      _ = try await service.insert("new", into: target)
      XCTFail("Expected cancellation")
    } catch is CancellationError {
      XCTAssertEqual(pasteboard.restored, original)
    }
  }

  func testSystemSnapshotDeepCopiesEveryItemAndHonorsByteLimit() throws {
    let native = NSPasteboard(name: .init("SpeakNoteTests-\(UUID().uuidString)"))
    native.clearContents()
    let first = NSPasteboardItem()
    first.setData(Data("abc".utf8), forType: .string)
    let second = NSPasteboardItem()
    second.setData(Data([1, 2]), forType: .init("public.data"))
    XCTAssertTrue(native.writeObjects([first, second]))
    let pasteboard = SystemPasteboard(pasteboard: native)

    let snapshot = try pasteboard.snapshot(maximumBytes: 5)
    XCTAssertEqual(snapshot.items.count, 2)
    XCTAssertEqual(
      snapshot.items[0].values[NSPasteboard.PasteboardType.string.rawValue], Data("abc".utf8))
    XCTAssertThrowsError(try pasteboard.snapshot(maximumBytes: 4))
  }
}

@MainActor
private final class FakeApplications: FrontmostApplicationProviding {
  var target: InsertionTarget?
  init(target: InsertionTarget?) { self.target = target }
}

@MainActor
private final class FakeCommandPoster: PasteCommandPosting {
  var canPostEvents = true
  var secureInputEnabled = false
  var postedPIDs: [pid_t] = []

  func postPaste(to processIdentifier: pid_t) -> Bool {
    postedPIDs.append(processIdentifier)
    return true
  }
}

@MainActor
private final class FakePasteboard: PasteboardAccessing {
  var changeCount = 0
  var snapshotFails = false
  private(set) var writeCount = 0
  private(set) var restored: PasteboardSnapshot?
  private var saved: PasteboardSnapshot
  private var token: String?

  init(snapshot: PasteboardSnapshot) {
    saved = snapshot
  }

  func snapshot(maximumBytes: Int) throws -> PasteboardSnapshot {
    if snapshotFails { throw FakeError.failed }
    return saved
  }

  func write(text: String, ownershipToken: String) -> Bool {
    writeCount += 1
    changeCount += 1
    token = ownershipToken
    return true
  }

  func owns(token: String, changeCount: Int) -> Bool {
    self.changeCount == changeCount && self.token == token
  }

  func restore(_ snapshot: PasteboardSnapshot) -> Bool {
    restored = snapshot
    saved = snapshot
    token = nil
    changeCount += 1
    return true
  }

  func simulateUserCopy() {
    changeCount += 1
    token = nil
  }

  private enum FakeError: Error {
    case failed
  }
}
