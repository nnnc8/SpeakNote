import Foundation

enum DiskCapacityError: Error, Equatable, Sendable {
  case unavailable
}

protocol DiskCapacityChecking: Sendable {
  func availableCapacity(at url: URL) async throws -> Int64
}

struct VolumeDiskCapacityChecker: DiskCapacityChecking {
  func availableCapacity(at url: URL) async throws -> Int64 {
    let values = try url.resourceValues(forKeys: [
      .volumeAvailableCapacityForImportantUsageKey
    ])
    guard let capacity = values.volumeAvailableCapacityForImportantUsage else {
      throw DiskCapacityError.unavailable
    }
    return capacity
  }
}
