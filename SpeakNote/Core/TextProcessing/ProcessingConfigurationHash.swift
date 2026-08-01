import CryptoKit
import Foundation

enum ProcessingConfigurationHash {
  static func make(
    _ configuration: TextProcessingConfiguration
  ) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(configuration)
    return SHA256.hash(data: data)
      .map { String(format: "%02x", $0) }
      .joined()
  }
}
